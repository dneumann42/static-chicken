;; runtime.scm — the static-chicken host. Compiled into the binary.
;;
;; Responsibilities:
;;   * spawn a TCP REPL server (sexp-over-TCP, 127.0.0.1:$REPL_PORT)
;;   * load main.scm + every .scm under src/ and plugins/, recursively
;;     relative to $STATIC_CHICKEN_APP_ROOT (defaults to cwd)
;;   * watch them; reload on mtime change
;;   * dispatch *on-draw* and *on-update* every frame, catch errors
;;   * broadcast errors to the on-screen overlay, stderr, and every REPL client
;;
;; Anything user code can call (init-window, draw-rectangle, ...) lives in
;; raylib.scm (also baked in). User-facing globals introduced here:
;;   *on-update*     thunk run every frame
;;   *on-draw*       thunk run every frame
;;   *last-error*     #f or a runtime-error record
;;   once! KEY THUNK  CL-defvar-style idempotent init

(declare (uses raylib))

(import (chicken base) (chicken eval) (chicken load)
        (chicken file) (chicken file.posix)
        (chicken memory representation)
        (chicken tcp)
        (chicken condition) (chicken format)
        (chicken pretty-print)
        (chicken process) (chicken process-context) (chicken port)
        (chicken string) (chicken sort)
        (srfi 1) (srfi 9) (srfi 18) (srfi 69))

;; ---------------------------------------------------------------------------
;; user-facing globals

(define *on-draw*     (lambda () #f))
(define *on-update*   (lambda () #f))
(define *last-error*   #f)
(define *last-error-text* #f)
(define *error-expanded?* #f)
(define *repl-clients* '())
(define *stdout-port* (current-output-port))
(define *stdout-log-installed?* #f)
(define *log-lines* '())
(define *log-partial* "")
(define *log-visible?* #f)
(define *log-scroll* 0)
(define *watch-visible?* #f)
(define *watch-input* "")
(define *watch-next-id* 1)
(define *pinned-watches* '())

(define *once-keys* (make-hash-table))
(define (once! key thunk)
  (unless (hash-table-exists? *once-keys* key)
    (hash-table-set! *once-keys* key #t)
    (thunk)))

;; ---------------------------------------------------------------------------
;; configuration

(define (env/default name default)
  (let ((value (get-environment-variable name)))
    (if (and value (not (string=? value ""))) value default)))

(define (absolute-path? path)
  (and (> (string-length path) 0)
       (char=? (string-ref path 0) #\/)))

(define (path-join root path)
  (if (or (string=? root "")
          (char=? (string-ref root (- (string-length root) 1)) #\/))
      (string-append root path)
      (string-append root "/" path)))

(define *app-root*
  (let ((root (env/default "STATIC_CHICKEN_APP_ROOT" (current-directory))))
    (if (absolute-path? root)
        root
        (path-join (current-directory) root))))

(define *app-entry* (env/default "STATIC_CHICKEN_ENTRY" "main.scm"))

(define *debug-font-path*
  (env/default "STATIC_CHICKEN_DEBUG_FONT"
               "vendor/static-chicken/assets/fonts/SpaceMono-Regular.ttf"))
(define *debug-font-attempted?* #f)

(define *log-max-lines*
  (or (and-let* ((s (get-environment-variable "STATIC_CHICKEN_LOG_LINES"))
                 (n (string->number s)))
        n)
      200))

(define *watch-dirs*
  (filter (lambda (s) (not (string=? s "")))
          (string-split (env/default "STATIC_CHICKEN_WATCH_DIRS" "src:plugins")
                        ":")))

(define (app-path path)
  (if (absolute-path? path)
      path
      (path-join *app-root* path)))

(define (ensure-debug-font!)
  (unless *debug-font-attempted?*
    (set! *debug-font-attempted?* #t)
    (let ((path (app-path *debug-font-path*)))
      (when (file-exists? path)
        (load-debug-font-ex path 22)))))

(define *repl-host* "127.0.0.1")
(define *repl-port*
  (or (and-let* ((s (get-environment-variable "REPL_PORT"))
                 (n (string->number s)))
        n)
      1234))

;; ---------------------------------------------------------------------------
;; condition formatting

(define-record-type <runtime-error>
  (make-runtime-error context message location arguments call-chain text)
  runtime-error?
  (context runtime-error-context)
  (message runtime-error-message)
  (location runtime-error-location)
  (arguments runtime-error-arguments)
  (call-chain runtime-error-call-chain)
  (text runtime-error-text))

(define exn-message
  (condition-property-accessor 'exn 'message #f))
(define exn-location
  (condition-property-accessor 'exn 'location #f))
(define exn-arguments
  (condition-property-accessor 'exn 'arguments '()))
(define exn-call-chain
  (condition-property-accessor 'exn 'call-chain '()))

(define (->display-string value)
  (with-output-to-string
    (lambda () (write value))))

(define (source-location? loc)
  (and (string? loc)
       (not (string=? loc "<syntax>"))
       (not (string=? loc "<eval>"))))

(define (call-chain-location chain)
  (let loop ((chain chain))
    (cond
      ((null? chain) #f)
      (else
       (let ((loc (vector-ref (car chain) 0)))
         (if (source-location? loc)
             loc
             (loop (cdr chain))))))))

(define (call-chain-line info)
  (let ((loc (vector-ref info 0))
        (expr (vector-ref info 1)))
    (string-append
     (if loc (->display-string loc) "<unknown>")
     "  "
     (if expr (->display-string expr) ""))))

(define (condition->runtime-error exn context)
  (cond
    ((condition? exn)
     (let* ((msg (or (exn-message exn) "(no message)"))
            (loc (exn-location exn))
            (args (exn-arguments exn))
            (chain (exn-call-chain exn))
            (source (or (call-chain-location chain)
                        (and loc (->display-string loc))))
            (text (format #f "~A~A~A~A"
                          (if context (format #f "~A: " context) "")
                          (if source (format #f "~A: " source) "")
                          msg
                          (if (pair? args)
                              (format #f ": ~S" args)
                              ""))))
       (make-runtime-error context msg source args chain text)))
    (else
     (let ((text (format #f "~A~A"
                         (if context (format #f "~A: " context) "")
                         exn)))
       (make-runtime-error context text #f '() '() text)))))

(define (condition->string exn)
  (runtime-error-text (condition->runtime-error exn #f)))

(define (runtime-error-lines err)
  (let ((chain (runtime-error-call-chain err))
        (base
         (append
          (list "static-chicken error"
                (runtime-error-text err))
          (if (runtime-error-location err)
              (list (format #f "line: ~A" (runtime-error-location err)))
              '())
          (if (pair? (runtime-error-arguments err))
              (list (format #f "arguments: ~S" (runtime-error-arguments err)))
              '()))))
    (if *error-expanded?*
        (append
         base
         (if (pair? chain)
             (cons "stacktrace:"
                   (map call-chain-line (take chain (min 18 (length chain)))))
             (list "stacktrace unavailable")))
        base)))

;; ---------------------------------------------------------------------------
(define (coerce-runtime-error value)
  (cond
    ((runtime-error? value) value)
    ((condition? value) (condition->runtime-error value #f))
    (else (make-runtime-error #f (format #f "~A" value) #f '() '()
                              (format #f "~A" value)))))

;; error broadcast (overlay + stderr + every REPL client)

(define (broadcast-error! err)
  (let* ((err (coerce-runtime-error err))
         (str (runtime-error-text err))
         (new? (not (and *last-error-text*
                         (string=? *last-error-text* str)))))
    (set! *last-error* err)
    (set! *last-error-text* str)
  ;; stderr
    (when new?
      (with-output-to-port (current-error-port)
        (lambda () (print "[error] " str))))
  ;; REPL clients — drop dead ones
    (when new?
      (set! *repl-clients*
            (filter
             (lambda (out)
               (handle-exceptions _ #f
                 (begin
                   (display "[error] " out)
                   (display str out)
                   (newline out)
                   (flush-output out)
                   #t)))
             *repl-clients*)))))

(define (clear-error!)
  (set! *last-error* #f)
  (set! *last-error-text* #f))

;; ---------------------------------------------------------------------------
;; stdout log capture

(define (trim-log-lines lines)
  (let ((count (length lines)))
    (if (> count *log-max-lines*)
        (drop lines (- count *log-max-lines*))
        lines)))

(define (append-log-line! line)
  (set! *log-lines* (trim-log-lines (append *log-lines* (list line))))
  (set! *log-scroll* (min *log-scroll* (max 0 (- (length *log-lines*) 1)))))

(define (capture-log-text! text)
  (let loop ((chars (string->list text)))
    (cond
      ((null? chars) #f)
      ((char=? (car chars) #\newline)
       (append-log-line! *log-partial*)
       (set! *log-partial* "")
       (loop (cdr chars)))
      (else
       (set! *log-partial*
             (string-append *log-partial* (string (car chars))))
       (loop (cdr chars))))))

(define (stdout-log-write text)
  (display text *stdout-port*)
  (capture-log-text! text))

(define (stdout-log-flush)
  (flush-output *stdout-port*))

(define (install-stdout-log!)
  (unless *stdout-log-installed?*
    (set! *stdout-log-installed?* #t)
    (current-output-port
     (make-output-port stdout-log-write
                       (lambda () (flush-output *stdout-port*))
                       stdout-log-flush))))

;; ---------------------------------------------------------------------------
;; pinned watch overlay

(define-record-type <pinned-watch>
  (make-pinned-watch id source thunk text)
  pinned-watch?
  (id pinned-watch-id)
  (source pinned-watch-source)
  (thunk pinned-watch-thunk)
  (text pinned-watch-text set-pinned-watch-text!))

(define (watch-visible-value value)
  (let ((seen (make-hash-table eq?)))
    (let loop ((value value)
               (depth 0))
      (cond
        ((> depth 16) '...)
        ((record-instance? value)
         (cond
           ((record-printer (record-instance-type value)) value)
           ((hash-table-exists? seen value) '...)
           (else
            (hash-table-set! seen value #t)
            (loop (record->vector value) (+ depth 1)))))
        ((pair? value)
         (cond
           ((hash-table-exists? seen value) '...)
           (else
            (hash-table-set! seen value #t)
            (cons (loop (car value) (+ depth 1))
                  (loop (cdr value) (+ depth 1))))))
        ((vector? value)
         (cond
           ((hash-table-exists? seen value) '#(...))
           (else
            (hash-table-set! seen value #t)
            (let* ((n (vector-length value))
                   (out (make-vector n)))
              (let fill ((i 0))
                (when (< i n)
                  (vector-set! out i (loop (vector-ref value i) (+ depth 1)))
                  (fill (+ i 1))))
              out))))
        (else value)))))

(define (pretty-value-string value)
  (let* ((s (with-output-to-string
              (lambda () (pretty-print (watch-visible-value value)))))
         (n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\newline))
        (substring s 0 (- n 1))
        s)))

(define (read-watch-expression source)
  (with-input-from-string source
    (lambda ()
      (let ((expr (read)))
        (if (eof-object? expr)
            (error "empty watch expression")
            expr)))))

(define (compile-watch-thunk source)
  (let ((expr (read-watch-expression source)))
    (eval `(lambda () ,expr) (interaction-environment))))

(define (add-pinned-watch! source)
  (let* ((thunk (compile-watch-thunk source))
         (watch (make-pinned-watch *watch-next-id*
                                   source
                                   thunk
                                   "(pending)")))
    (set! *watch-next-id* (+ *watch-next-id* 1))
    (set! *pinned-watches* (append *pinned-watches* (list watch)))))

(define (trim-whitespace s)
  (let* ((n (string-length s))
         (start (let loop ((i 0))
                  (cond
                    ((>= i n) n)
                    ((char-whitespace? (string-ref s i)) (loop (+ i 1)))
                    (else i))))
         (end (let loop ((i (- n 1)))
                (cond
                  ((< i start) start)
                  ((char-whitespace? (string-ref s i)) (loop (- i 1)))
                  (else (+ i 1))))))
    (substring s start end)))

(define (submit-watch-input!)
  (let ((source (trim-whitespace *watch-input*)))
    (unless (string=? source "")
      (handle-exceptions exn
        (broadcast-error! (condition->runtime-error exn "watch"))
        (add-pinned-watch! source)
        (set! *watch-input* "")))))

(define (update-pinned-watch! watch)
  (set-pinned-watch-text!
   watch
   (handle-exceptions exn
     (string-append "[error] " (condition->string exn))
     (pretty-value-string ((pinned-watch-thunk watch))))))

(define (update-pinned-watches!)
  (for-each update-pinned-watch! *pinned-watches*))

(define (watch-panel-layout)
  (let* ((pad 12)
         (panel-width (min (- (get-screen-width) 16) 1120))
         (panel-height 82)
         (x 8)
         (log-layout (and *log-visible?* (log-panel-layout)))
         (bottom (if log-layout
                     (- (list-ref log-layout 1) 8)
                     (- (get-screen-height) 8)))
         (y (- bottom panel-height)))
    (list x y panel-width panel-height pad)))

(define (watch-input-display)
  (string-append "> " *watch-input*
                 (if *watch-visible?* "_" "")))

(define (toggle-watch-panel!)
  (when (key-pressed? key-f9)
    (set! *watch-visible?* (not *watch-visible?*))))

(define (trim-last-char s)
  (let ((n (string-length s)))
    (if (> n 0)
        (substring s 0 (- n 1))
        s)))

(define (handle-watch-panel-actions!)
  (toggle-watch-panel!)
  (when *watch-visible?*
    (let ((typed (get-text-input)))
      (unless (string=? typed "")
        (set! *watch-input* (string-append *watch-input* typed))))
    (when (or (key-pressed? key-backspace)
              (key-pressed-repeat? key-backspace))
      (set! *watch-input* (trim-last-char *watch-input*)))
    (when (key-pressed? key-enter)
      (submit-watch-input!))
    (when (key-pressed? key-escape)
      (set! *watch-visible?* #f))))

(define (watch-sticker-lines watch)
  (append
   (wrap-line (pinned-watch-source watch) 34)
   (append-map (lambda (line) (wrap-line line 38))
               (string-split (pinned-watch-text watch) "\n"))))

(define (watch-sticker-layouts)
  (let* ((screen-width (get-screen-width))
         (screen-height (get-screen-height))
         (margin 8)
         (pad 10)
         (line-height 20)
         (sticker-width (min 360 (max 220 (- screen-width (* margin 2)))))
         (max-y (- screen-height margin))
         (start-y 8))
    (let loop ((watches *pinned-watches*)
               (x margin)
               (y start-y)
               (row-height 0)
               (out '()))
      (cond
        ((null? watches)
         (reverse out))
        (else
         (let* ((watch (car watches))
                (lines (watch-sticker-lines watch))
                (height (+ (* line-height (length lines)) (* pad 2)))
                (next-x (+ x sticker-width margin))
                (fits-row? (<= next-x screen-width))
                (place-x (if fits-row? x margin))
                (place-y (if fits-row? y (+ y row-height margin)))
                (place-y (if (> (+ place-y height) max-y) start-y place-y))
                (next-row-height (if fits-row?
                                     (max row-height height)
                                     height)))
           (loop (cdr watches)
                 (+ place-x sticker-width margin)
                 place-y
                 next-row-height
                 (cons (list watch place-x place-y sticker-width height lines)
                       out))))))))

(define (remove-pinned-watch-at! mx my)
  (let* ((layouts (watch-sticker-layouts))
         (hit (find (lambda (layout)
                      (point-in-rect? mx my
                                      (list-ref layout 1)
                                      (list-ref layout 2)
                                      (list-ref layout 3)
                                      (list-ref layout 4)))
                    layouts)))
    (when hit
      (let ((id (pinned-watch-id (car hit))))
        (set! *pinned-watches*
              (filter (lambda (watch)
                        (not (= (pinned-watch-id watch) id)))
                      *pinned-watches*))))))

(define (handle-pinned-watch-actions!)
  (when (mouse-button-pressed? mouse-button-right)
    (remove-pinned-watch-at! (get-mouse-x) (get-mouse-y))))

(define (draw-pinned-watches)
  (when (pair? *pinned-watches*)
    (ensure-debug-font!)
    (for-each
     (lambda (layout)
       (let ((watch (list-ref layout 0))
             (x (list-ref layout 1))
             (y (list-ref layout 2))
             (w (list-ref layout 3))
             (h (list-ref layout 4))
             (lines (list-ref layout 5))
             (pad 10)
             (line-height 20))
         (draw-rectangle x y w h 14 16 18 220)
         (draw-rectangle-lines x y w h 125 225 185 255)
         (let loop ((ls lines)
                    (line-y (+ y pad))
                    (index 0))
           (when (pair? ls)
             (draw-debug-text (truncate-line (car ls) 42)
                              (+ x pad)
                              line-y
                              (if (= index 0) 16 15)
                              (if (= index 0) 150 225)
                              (if (= index 0) 255 235)
                              (if (= index 0) 195 225)
                              255)
             (loop (cdr ls) (+ line-y line-height) (+ index 1))))))
     (watch-sticker-layouts))))

(define (draw-watch-panel)
  (when *watch-visible?*
    (ensure-debug-font!)
    (let* ((layout (watch-panel-layout))
           (x (list-ref layout 0))
           (y (list-ref layout 1))
           (w (list-ref layout 2))
           (h (list-ref layout 3))
           (pad (list-ref layout 4)))
      (draw-rectangle x y w h 10 12 14 225)
      (draw-rectangle-lines x y w h 125 225 185 255)
      (draw-debug-text
       (format #f "watch - F9 hide - Enter pin - right-click sticker remove - ~A pinned"
               (length *pinned-watches*))
       (+ x pad) (+ y pad) 18 150 255 205 255)
      (draw-debug-text (truncate-line (watch-input-display) 128)
                       (+ x pad)
                       (+ y pad 34)
                       18
                       225 235 230 255))))

;; ---------------------------------------------------------------------------
;; safe wrappers

(define (safe-call! thunk)
  (handle-exceptions exn
    (broadcast-error! (condition->runtime-error exn #f))
    (thunk)))

(define (try-load path)
  (handle-exceptions exn
    (cons #f (condition->runtime-error exn (format #f "load ~A" path)))
    (load path)
    (cons #t #f)))

(define (safe-load! path)
  (let ((result (try-load path)))
    (if (car result)
        (clear-error!)
        (broadcast-error! (cdr result)))))

(define (load-files! paths)
  (let loop ((pending paths) (last-errors '()))
    (cond
      ((null? pending)
       (clear-error!))
      (else
       (let pass ((rest pending)
                  (next '())
                  (errors '())
                  (loaded? #f))
         (cond
           ((null? rest)
            (cond
              (loaded?
               (loop (reverse next) errors))
              (else
               (for-each broadcast-error! (reverse errors)))))
           (else
            (let* ((path (car rest))
                   (result (try-load path)))
              (if (car result)
                  (pass (cdr rest) next errors #t)
                  (pass (cdr rest)
                        (cons path next)
                        (cons (cdr result) errors)
                        loaded?))))))))))

;; ---------------------------------------------------------------------------
;; file watcher

(define *watch-mtimes* (make-hash-table equal?))

(define (scm-file? path)
  (let ((p (if (string? path) path (->string path)))
        (suf ".scm"))
    (let ((lp (string-length p)) (ls (string-length suf)))
      (and (>= lp ls)
           (string=? (substring p (- lp ls) lp) suf)))))

(define (enumerate-source-files)
  (let ((files '()))
    (for-each
     (lambda (dir)
       (let ((rooted-dir (app-path dir)))
         (when (and (file-exists? rooted-dir) (directory? rooted-dir))
           (set! files
                 (append (find-files rooted-dir test: scm-file?) files)))))
     *watch-dirs*)
    (sort (delete-duplicates files string=?) string<?)))

(define (enumerate-watch-files)
  (let ((entry (app-path *app-entry*)))
    (append
     (enumerate-source-files)
     (if (file-exists? entry) (list entry) '()))))

(define (file-mtime-or-zero path)
  (handle-exceptions _ 0 (file-modification-time path)))

(define (check-watches!)
  (let ((changed '()))
    (for-each
     (lambda (path)
       (let ((cur  (file-mtime-or-zero path))
             (prev (hash-table-ref/default *watch-mtimes* path 0)))
         (when (and (> cur 0) (not (= cur prev)))
           (hash-table-set! *watch-mtimes* path cur)
           (when (> prev 0)
             (print "[reload] " path)
             (flush-output))
           (set! changed (cons path changed)))))
     (enumerate-watch-files))
    (unless (null? changed)
      (load-files! (reverse changed)))))

;; ---------------------------------------------------------------------------
;; on-screen error overlay

(define (truncate-line s limit)
  (if (> (string-length s) limit)
      (string-append (substring s 0 (max 0 (- limit 1))) "...")
      s))

(define (wrap-line s limit)
  (let loop ((remaining s) (out '()))
    (if (<= (string-length remaining) limit)
        (reverse (cons remaining out))
        (let scan ((i limit))
          (cond
            ((<= i 20)
             (loop (substring remaining limit (string-length remaining))
                   (cons (substring remaining 0 limit) out)))
            ((char-whitespace? (string-ref remaining i))
             (loop (substring remaining (+ i 1) (string-length remaining))
                   (cons (substring remaining 0 i) out)))
            (else
             (scan (- i 1))))))))

(define (clamp n low high)
  (cond
    ((< n low) low)
    ((> n high) high)
    (else n)))

(define (overlay-lines err)
  (append-map (lambda (line) (wrap-line line 96))
              (runtime-error-lines err)))

(define (error-panel-layout err)
  (let* ((lines (overlay-lines err))
         (visible (take lines (min (length lines) (if *error-expanded?* 22 8))))
         (line-height 25)
         (pad 12)
         (panel-width (min (- (get-screen-width) 16) 1120))
         (panel-height (+ (* line-height (length visible)) (* pad 2) 22)))
    (list 8 8 panel-width panel-height visible line-height pad)))

(define (toggle-error-expanded!)
  (when (key-pressed? key-f8)
    (set! *error-expanded?* (not *error-expanded?*))))

(define (string-last-colon s)
  (string-last-colon-before s (string-length s)))

(define (string-last-colon-before s end)
  (let loop ((index (- end 1)))
    (cond
      ((< index 0) #f)
      ((char=? (string-ref s index) #\:) index)
      (else (loop (- index 1))))))

(define (digit-string? s)
  (and (> (string-length s) 0)
       (let loop ((index 0))
         (cond
           ((= index (string-length s)) #t)
           ((char-numeric? (string-ref s index))
            (loop (+ index 1)))
           (else #f)))))

(define (string-prefix? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (parse-error-location loc)
  (and (string? loc)
       (let* ((last-colon (string-last-colon loc))
              (prev-colon (and last-colon
                               (string-last-colon-before loc last-colon)))
              (last-part (and last-colon
                              (substring loc (+ last-colon 1)
                                         (string-length loc))))
              (prev-part (and prev-colon last-colon
                              (substring loc (+ prev-colon 1) last-colon)))
              (colon (if (and prev-colon
                              (digit-string? prev-part)
                              (digit-string? last-part))
                         prev-colon
                         last-colon))
              (column (and (eq? colon prev-colon)
                           (string->number last-part))))
         (and colon
              (let ((path (substring loc 0 colon))
                    (line (if (eq? colon prev-colon)
                              prev-part
                              (substring loc (+ colon 1)
                                         (string-length loc)))))
                (and (not (string=? path ""))
                     (not (string=? path "<stdin>"))
                     (not (string=? path "<eval>"))
                     (digit-string? line)
                     (list (app-path path)
                           (string->number line)
                           column)))))))

(define (quoted-prefix s)
  (and (> (string-length s) 1)
       (char=? (string-ref s 0) #\")
       (let loop ((index 1))
         (cond
           ((= index (string-length s)) #f)
           ((char=? (string-ref s index) #\")
            (substring s 1 index))
           (else
            (loop (+ index 1)))))))

(define (panel-line-location line)
  (cond
    ((string-prefix? "line: " line)
     (parse-error-location (substring line 6 (string-length line))))
    ((quoted-prefix line) => parse-error-location)
    (else #f)))

(define (executable-on-path command)
  (let ((path (get-environment-variable "PATH")))
    (and path
         (let loop ((dirs (string-split path ":")))
           (cond
             ((null? dirs) #f)
             (else
              (let ((candidate (path-join (car dirs) command)))
                (if (and (file-exists? candidate)
                         (not (directory? candidate)))
                    candidate
                    (loop (cdr dirs))))))))))

(define (open-target-location! target)
  (when target
    (let* ((file (list-ref target 0))
           (line (list-ref target 1))
           (column (list-ref target 2))
           (line-arg (format #f "+~A~A"
                             line
                             (if column (format #f ":~A" column) "")))
           (emacsclient (executable-on-path "emacsclient")))
      (handle-exceptions exn
        (broadcast-error! (condition->runtime-error exn "open editor"))
        (if emacsclient
            (process-run emacsclient (list "-n" line-arg file))
            (broadcast-error!
             "open editor: emacsclient not found on PATH"))))))

(define (open-error-location! err line)
  (let ((target (or (and line (panel-line-location line))
                    (parse-error-location (runtime-error-location err)))))
    (when target
      (open-target-location! target))))

(define (point-in-rect? px py x y w h)
  (and (>= px x)
       (< px (+ x w))
       (>= py y)
       (< py (+ y h))))

(define (error-panel-clicked? layout)
  (and (mouse-button-pressed? mouse-button-left)
       (point-in-rect? (get-mouse-x) (get-mouse-y)
                       (list-ref layout 0)
                       (list-ref layout 1)
                       (list-ref layout 2)
                       (list-ref layout 3))))

(define (hovered-error-line-index layout)
  (let* ((mx (get-mouse-x))
         (my (get-mouse-y))
         (x (list-ref layout 0))
         (y (list-ref layout 1))
         (w (list-ref layout 2))
         (visible (list-ref layout 4))
         (line-height (list-ref layout 5))
         (pad (list-ref layout 6))
         (line-top (+ y pad 24))
         (line-index (quotient (- my line-top) line-height)))
    (and (>= mx (+ x pad))
         (< mx (+ x w (- pad)))
         (>= line-index 0)
         (< line-index (length visible))
         line-index)))

(define (handle-error-actions! err)
  (let* ((layout (error-panel-layout err))
         (visible (list-ref layout 4))
         (hovered-line-index (hovered-error-line-index layout))
         (hovered-line (and hovered-line-index
                            (list-ref visible hovered-line-index))))
    (cond
      ((key-pressed? key-f11)
       (open-error-location! err #f))
      ((error-panel-clicked? layout)
       (open-error-location! err hovered-line)))))

(define (draw-error-overlay err)
  (ensure-debug-font!)
  (let* ((layout (error-panel-layout err))
         (x (list-ref layout 0))
         (y (list-ref layout 1))
         (panel-width (list-ref layout 2))
         (panel-height (list-ref layout 3))
         (visible (list-ref layout 4))
         (line-height (list-ref layout 5))
         (pad (list-ref layout 6))
         (hovered-line (hovered-error-line-index layout)))
    (draw-rectangle x y panel-width panel-height 12 12 16 225)
    (draw-rectangle-lines x y panel-width panel-height 255 90 90 255)
    (draw-debug-text (if *error-expanded?*
                         "error - F8 collapse - F11/click open"
                         "error - F8 expand - F11/click open")
                     (+ x pad) (+ y pad) 20 255 120 120 255)
    (let loop ((ls visible)
               (line-y (+ y pad 24))
               (index 0))
      (when (pair? ls)
        (let* ((text (truncate-line (car ls) 120))
               (font-size (if (= index 0) 20 18))
               (r (if (= index 0) 255 220))
               (g (if (= index 0) 190 210))
               (b (if (= index 0) 190 220))
               (text-x (+ x pad)))
          (draw-debug-text text text-x line-y font-size r g b 255)
          (when (and hovered-line (= hovered-line index))
            (draw-line text-x
                       (+ line-y font-size 3)
                       (+ text-x (measure-text text font-size))
                       (+ line-y font-size 3)
                       r g b 255)))
        (loop (cdr ls) (+ line-y line-height) (+ index 1))))))

(define (log-source-lines)
  (if (string=? *log-partial* "")
      *log-lines*
      (append *log-lines* (list *log-partial*))))

(define (log-wrapped-lines)
  (append-map (lambda (line) (wrap-line line 110))
              (log-source-lines)))

(define (log-panel-layout)
  (let* ((line-height 22)
         (pad 12)
         (header-height 28)
         (panel-width (min (- (get-screen-width) 16) 1120))
         (max-body-height (max 90 (- (get-screen-height) 180)))
         (panel-height (min 340 max-body-height))
         (visible-count (max 1
                             (quotient (- panel-height
                                          header-height
                                          (* pad 2))
                                       line-height)))
         (x 8)
         (y (- (get-screen-height) panel-height 8)))
    (list x y panel-width panel-height visible-count line-height pad header-height)))

(define (visible-log-lines layout)
  (let* ((lines (log-wrapped-lines))
         (visible-count (list-ref layout 4))
         (total (length lines))
         (max-scroll (max 0 (- total visible-count))))
    (set! *log-scroll* (clamp *log-scroll* 0 max-scroll))
    (let* ((start (max 0 (- total visible-count *log-scroll*)))
           (end (min total (+ start visible-count))))
      (take (drop lines start) (- end start)))))

(define (toggle-log-panel!)
  (when (key-pressed? key-f10)
    (set! *log-visible?* (not *log-visible?*))))

(define (scroll-log! delta layout)
  (let* ((lines (log-wrapped-lines))
         (visible-count (list-ref layout 4))
         (max-scroll (max 0 (- (length lines) visible-count))))
    (set! *log-scroll*
          (clamp (+ *log-scroll* delta) 0 max-scroll))))

(define (handle-log-actions!)
  (toggle-log-panel!)
  (when *log-visible?*
    (let ((layout (log-panel-layout))
          (wheel (get-mouse-wheel-move)))
      (cond
        ((> wheel 0.0) (scroll-log! 3 layout))
        ((< wheel 0.0) (scroll-log! -3 layout)))
      (cond
        ((key-pressed? key-page-up) (scroll-log! 8 layout))
        ((key-pressed? key-page-down) (scroll-log! -8 layout))))))

(define (draw-log-overlay)
  (when *log-visible?*
    (ensure-debug-font!)
    (let* ((layout (log-panel-layout))
           (x (list-ref layout 0))
           (y (list-ref layout 1))
           (panel-width (list-ref layout 2))
           (panel-height (list-ref layout 3))
           (line-height (list-ref layout 5))
           (pad (list-ref layout 6))
           (header-height (list-ref layout 7))
           (lines (visible-log-lines layout))
           (total (length (log-wrapped-lines))))
      (draw-rectangle x y panel-width panel-height 10 12 14 225)
      (draw-rectangle-lines x y panel-width panel-height 105 170 230 255)
      (draw-debug-text
       (format #f "stdout - F10 hide - wheel/PageUp/PageDown scroll - ~A/~A lines"
               (length *log-lines*)
               *log-max-lines*)
       (+ x pad) (+ y pad) 18 150 205 255 255)
      (let loop ((ls lines)
                 (line-y (+ y pad header-height)))
        (when (pair? ls)
          (draw-debug-text (truncate-line (car ls) 132)
                           (+ x pad)
                           line-y
                           16
                           220 230 235 255)
          (loop (cdr ls) (+ line-y line-height)))))))

;; ---------------------------------------------------------------------------
;; TCP REPL

(define *repl-listener* #f)

(define (start-repl-server!)
  (handle-exceptions exn
    (fprintf (current-error-port)
             "[repl] could not bind ~A:~A — ~A~%"
             *repl-host* *repl-port* (condition->string exn))
    (set! *repl-listener* (tcp-listen *repl-port* 4 *repl-host*))
    (fprintf (current-error-port)
             "[repl] listening on ~A:~A~%"
             *repl-host* *repl-port*)))

;; Polled from the frame loop. Single-thread design: poll for new connections
;; and per-client readability with tcp-accept-ready? / char-ready?, so we never
;; block on I/O. The frame loop drives everything.
(define *repl-conns* '())   ; ((in out partial) ...)

(define (poll-repl-accept!)
  (when (and *repl-listener*
             (handle-exceptions _ #f (tcp-accept-ready? *repl-listener*)))
    (handle-exceptions exn
      (fprintf (current-error-port)
               "[repl] accept failed: ~A~%"
               (condition->string exn))
      (receive (in out) (tcp-accept *repl-listener*)
        (display ";; static-chicken REPL — eval shares the live image.\n" out)
        (display ";; type Ctrl-D or ,quit to disconnect.\n> " out)
        (flush-output out)
        (set! *repl-clients* (cons out *repl-clients*))
        (set! *repl-conns* (cons (list in out) *repl-conns*))))))

(define (drop-conn! out)
  (set! *repl-clients*
        (filter (lambda (p) (not (eq? p out))) *repl-clients*)))

(define (handle-conn! in out)
  ;; Returns #t if the connection should remain in the active set, #f to drop.
  (cond
    ((not (handle-exceptions _ #f (char-ready? in)))
     #t)                                   ; idle — keep
    (else
     (handle-exceptions exn
       (begin
         (display "[error] " out)
         (display (condition->string exn) out)
         (display "\n> " out)
         (flush-output out)
         #t)
       (let ((expr (read in)))
         (cond
           ((or (eof-object? expr) (equal? expr ',quit))
            (drop-conn! out)
            (handle-exceptions _ #f (close-input-port in))
            (handle-exceptions _ #f (close-output-port out))
            #f)
           (else
            (let ((result (eval expr (interaction-environment))))
              (write result out)
              (display "\n> " out)
              (flush-output out)
              #t))))))))

(define (poll-repl-input!)
  (set! *repl-conns*
        (filter (lambda (c) (handle-conn! (car c) (cadr c)))
                *repl-conns*)))

;; ---------------------------------------------------------------------------
;; Helpers
(define-syntax define-update
  (syntax-rules ()
    ((_ (arg ...) body ...)
     (set! *on-update*
       (lambda (arg ...)
         body ...)))))

(define-syntax define-draw
  (syntax-rules ()
    ((_ (arg ...) body ...)
     (set! *on-draw*
       (lambda (arg ...)
         body ...)))))

(define (install-helper-syntax!)
  (eval
   '(define-syntax define-update
      (syntax-rules ()
        ((_ (arg ...) body ...)
         (set! *on-update*
           (lambda (arg ...)
             body ...)))))
   (interaction-environment))
  (eval
   '(define-syntax define-draw
      (syntax-rules ()
        ((_ (arg ...) body ...)
         (set! *on-draw*
           (lambda (arg ...)
             body ...)))))
   (interaction-environment)))

;; ---------------------------------------------------------------------------
;; main

(define (frame!)
  (poll-repl-accept!)
  (poll-repl-input!)
  (check-watches!)
  (cond
   ((not (is-window-ready?))
    (thread-sleep! 0.05))
   ((window-should-close?)
    #f)
   (else
    (when *last-error* (toggle-error-expanded!))
    (when *last-error* (handle-error-actions! *last-error*))
    (handle-log-actions!)
    (handle-watch-panel-actions!)
    (safe-call! *on-update*)
    (update-pinned-watches!)
    (handle-pinned-watch-actions!)
    (begin-drawing)
    (clear-background (make-color 30 30 40))
    (safe-call! *on-draw*)
    (draw-pinned-watches)
    (draw-log-overlay)
    (draw-watch-panel)
    (when *last-error* (draw-error-overlay *last-error*))
    (end-drawing)))
  (thread-yield!))

(define (main)
  (install-stdout-log!)
  (start-repl-server!)
  (install-helper-syntax!)
  (check-watches!)
  (let loop ()
    (frame!)
    (cond
      ((and (is-window-ready?) (window-should-close?))
       (close-window))
      (else
       (loop)))))

(main)
