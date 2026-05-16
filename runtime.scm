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
        (chicken tcp)
        (chicken condition) (chicken format)
        (chicken process-context) (chicken port)
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

(define (overlay-lines err)
  (append-map (lambda (line) (wrap-line line 96))
              (runtime-error-lines err)))

(define (toggle-error-expanded!)
  (when (key-pressed? key-f8)
    (set! *error-expanded?* (not *error-expanded?*))))

(define (draw-error-overlay err)
  (ensure-debug-font!)
  (let* ((lines (overlay-lines err))
         (visible (take lines (min (length lines) (if *error-expanded?* 22 8))))
         (line-height 25)
         (pad 12)
         (panel-width (min (- (get-screen-width) 16) 1120))
         (panel-height (+ (* line-height (length visible)) (* pad 2) 22))
         (x 8)
         (y 8))
    (draw-rectangle x y panel-width panel-height 12 12 16 225)
    (draw-rectangle-lines x y panel-width panel-height 255 90 90 255)
    (draw-debug-text (if *error-expanded?*
                         "error - F8 collapse"
                         "error - F8 expand")
                     (+ x pad) (+ y pad) 20 255 120 120 255)
    (let loop ((ls visible)
               (line-y (+ y pad 24))
               (index 0))
      (when (pair? ls)
        (draw-debug-text (truncate-line (car ls) 120)
                         (+ x pad)
                         line-y
                         (if (= index 0) 20 18)
                         (if (= index 0) 255 220)
                         (if (= index 0) 190 210)
                         (if (= index 0) 190 220)
                         255)
        (loop (cdr ls) (+ line-y line-height) (+ index 1))))))

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
    (safe-call! *on-update*)
    (begin-drawing)
    (clear-background (make-color 30 30 40))
    (safe-call! *on-draw*)
    (when *last-error* (draw-error-overlay *last-error*))
    (end-drawing)))
  (thread-yield!))

(define (main)
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
