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
  (let* ((s (cond
              ((eq? value #t) "true")
              ((eq? value #f) "false")
              (else
               (with-output-to-string
                 (lambda () (pretty-print (watch-visible-value value)))))))
         (n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\newline))
        (remove-debug-font-markers (substring s 0 (- n 1)))
        (remove-debug-font-markers s))))

(define (remove-debug-font-markers s)
  (list->string
   (filter (lambda (ch) (not (char=? ch #\#)))
           (string->list s))))

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
         (panel-height (min 280 (max 140 (- (get-screen-height) 24))))
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

(define (string-join-comma values)
  (cond
    ((null? values) "")
    (else
     (let loop ((values (cdr values))
                (out (car values)))
       (if (null? values)
           out
           (loop (cdr values)
                 (string-append out ", " (car values))))))))

(define (definition-name form)
  (cond
    ((and (pair? form)
          (eq? (car form) 'define)
          (pair? (cdr form)))
     (let ((name (cadr form)))
       (cond
         ((symbol? name) (list name))
         ((and (pair? name) (symbol? (car name))) (list (car name)))
         (else '()))))
    ((and (pair? form)
          (eq? (car form) 'define-record-type)
          (pair? (cdr form)))
     (let ((parts (cdr form)))
       (filter symbol?
               (append
                (take parts (min 3 (length parts)))
                (append-map
                 (lambda (field)
                   (if (pair? field) (filter symbol? (cdr field)) '()))
                 (drop parts (min 3 (length parts))))))))
    (else '())))

(define (collect-global-names-in forms)
  (let loop ((forms forms) (acc '()))
    (cond
      ((null? forms) acc)
      ((not (pair? (car forms))) (loop (cdr forms) acc))
      (else
       (let ((form (car forms)))
         (cond
           ((and (pair? form) (eq? (car form) 'module))
            (loop (cdr forms)
                  (append (collect-global-names-in (cdddr form)) acc)))
           ((and (pair? form) (memq (car form) '(begin cond-expand)))
            (loop (cdr forms)
                  (append (collect-global-names-in (cdr form)) acc)))
           (else
            (loop (cdr forms) (append (definition-name form) acc)))))))))

(define (global-source-files)
  (let ((raylib (app-path "vendor/static-chicken/raylib.scm")))
    (append (enumerate-watch-files)
            (if (file-exists? raylib) (list raylib) '()))))

(define (global-cache-key files)
  (map (lambda (path) (cons path (file-mtime-or-zero path))) files))

(define runtime-global-names
  '("*on-update*" "*on-draw*" "*last-error*" "*last-error-text*"
    "*error-expanded?*" "*log-visible?*" "*watch-visible?*"
    "*pinned-watches*" "once!" "clear-error!"))

(define (available-global-names)
  (let* ((files (global-source-files))
         (key (global-cache-key files)))
    (cond
      ((and *watch-global-cache*
            (equal? (vector-ref *watch-global-cache* 0) key))
       (vector-ref *watch-global-cache* 1))
      (else
       (let* ((source-names
               (append-map
                (lambda (path)
                  (map symbol->string
                       (collect-global-names-in (read-all-forms path))))
                files))
              (names (sort (delete-duplicates
                            (append runtime-global-names source-names)
                            string=?)
                           string<?)))
         (set! *watch-global-cache* (vector key names))
         names)))))

(define (watch-global-lines width)
  (let* ((chars (max 24 (quotient (- width 24) 9)))
         (text (string-join-comma (available-global-names))))
    (if (string=? text "")
        (list "(no globals found)")
        (wrap-line text chars))))

(define (visible-watch-global-lines layout)
  (let* ((w (list-ref layout 2))
         (h (list-ref layout 3))
         (lines (watch-global-lines w))
         (visible-count (max 1 (quotient (- h 100) 20)))
         (max-scroll (max 0 (- (length lines) visible-count))))
    (set! *watch-global-scroll*
          (clamp *watch-global-scroll* 0 max-scroll))
    (let* ((start *watch-global-scroll*)
           (end (min (length lines) (+ start visible-count))))
      (list (drop lines start) visible-count (length lines)))))

(define (scroll-watch-globals! delta layout)
  (let* ((visible (visible-watch-global-lines layout))
         (visible-count (list-ref visible 1))
         (total (list-ref visible 2))
         (max-scroll (max 0 (- total visible-count))))
    (set! *watch-global-scroll*
          (clamp (+ *watch-global-scroll* delta) 0 max-scroll))))

(define (toggle-watch-panel!)
  (when (key-pressed? key-f9)
    (set! *watch-visible?* (not *watch-visible?*))))

(define (trim-last-char s)
  (let ((n (string-length s)))
    (if (> n 0)
        (substring s 0 (- n 1))
        s)))

(define (watch-input-char-key ch)
  (cond
    ((char-alphabetic? ch)
     (+ key-a (- (char->integer (char-upcase ch)) (char->integer #\A))))
    ((char-numeric? ch)
     (+ key-zero (- (char->integer ch) (char->integer #\0))))
    ((char=? ch #\space) key-space)
    ((or (char=? ch #\-) (char=? ch #\_)) key-minus)
    ((or (char=? ch #\=) (char=? ch #\+)) key-equal)
    ((or (char=? ch #\[) (char=? ch #\{)) key-left-bracket)
    ((or (char=? ch #\]) (char=? ch #\})) key-right-bracket)
    ((or (char=? ch #\\) (char=? ch #\|)) key-backslash)
    ((or (char=? ch #\;) (char=? ch #\:)) key-semicolon)
    ((or (char=? ch #\') (char=? ch #\")) key-apostrophe)
    ((or (char=? ch #\,) (char=? ch #\<)) key-comma)
    ((or (char=? ch #\.) (char=? ch #\>)) key-period)
    ((or (char=? ch #\/) (char=? ch #\?)) key-slash)
    ((or (char=? ch #\`) (char=? ch #\~)) key-grave)
    ((char=? ch #\!) key-one)
    ((char=? ch #\@) key-two)
    ((char=? ch #\#) key-three)
    ((char=? ch #\$) key-four)
    ((char=? ch #\%) key-five)
    ((char=? ch #\^) key-six)
    ((char=? ch #\&) key-seven)
    ((char=? ch #\*) key-eight)
    ((char=? ch #\() key-nine)
    ((char=? ch #\)) key-zero)
    (else #f)))

(define (watch-input-char-pressed? ch)
  (let ((key (watch-input-char-key ch)))
    (and key (key-pressed? key))))

(define (pressed-text-input typed)
  (let loop ((i 0) (chars '()))
    (if (>= i (string-length typed))
        (list->string (reverse chars))
        (let ((ch (string-ref typed i)))
          (loop (+ i 1)
                (if (watch-input-char-pressed? ch)
                    (cons ch chars)
                    chars))))))

(define (append-watch-text-input! typed)
  (let ((pressed (pressed-text-input typed)))
    (unless (string=? pressed "")
      (set! *watch-input* (string-append *watch-input* pressed)))))

(define (handle-watch-panel-actions!)
  (toggle-watch-panel!)
  (when *watch-visible?*
    (let ((typed (get-text-input)))
      (unless (string=? typed "")
        (append-watch-text-input! typed)))
    (when (or (key-pressed? key-backspace)
              (key-pressed-repeat? key-backspace))
      (set! *watch-input* (trim-last-char *watch-input*)))
    (when (key-pressed? key-enter)
      (submit-watch-input!))
    (let ((layout (watch-panel-layout))
          (wheel (get-mouse-wheel-move)))
      (cond
        ((> wheel 0.0) (scroll-watch-globals! -3 layout))
        ((< wheel 0.0) (scroll-watch-globals! 3 layout)))
      (cond
        ((key-pressed? key-page-up) (scroll-watch-globals! -8 layout))
        ((key-pressed? key-page-down) (scroll-watch-globals! 8 layout))))
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
           (pad (list-ref layout 4))
           (global-info (visible-watch-global-lines layout))
           (global-lines (list-ref global-info 0))
           (visible-count (list-ref global-info 1))
           (total-count (list-ref global-info 2)))
      (draw-rectangle x y w h 10 12 14 225)
      (draw-rectangle-lines x y w h 125 225 185 255)
      (draw-debug-text
       (format #f "watch - F9 hide - Enter pin - wheel/PageUp/PageDown globals - ~A pinned"
               (length *pinned-watches*))
       (+ x pad) (+ y pad) 18 150 255 205 255)
      (draw-debug-text
       (format #f "globals ~A/~A"
               (min total-count (+ *watch-global-scroll* visible-count))
               total-count)
       (+ x pad) (+ y pad 28) 15 150 225 255 255)
      (let loop ((lines global-lines)
                 (line-y (+ y pad 50)))
        (when (and (pair? lines)
                   (< line-y (- (+ y h) 42)))
          (draw-debug-text (car lines)
                           (+ x pad)
                           line-y
                           15
                           210 220 215 255)
          (loop (cdr lines) (+ line-y 20))))
      (draw-debug-text (truncate-line (watch-input-display) 128)
                       (+ x pad)
                       (- (+ y h) 30)
                       18
                       225 235 230 255))))
