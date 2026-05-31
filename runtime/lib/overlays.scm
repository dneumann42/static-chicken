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

;; ---------------------------------------------------------------------------
;; runtime debug overlay

(define (toggle-debug-overlay!)
  (when (key-pressed? key-f12)
    (debug-visible? (not (debug-visible?)))))

(define (update-debug-frame!)
  (let* ((sample-count (vector-length *debug-fps-samples*))
         (dt (max 0.0 (get-frame-time)))
         (old (vector-ref *debug-fps-samples* *debug-fps-index*)))
    (vector-set! *debug-fps-samples* *debug-fps-index* dt)
    (set! *debug-fps-total* (+ (- *debug-fps-total* old) dt))
    (set! *debug-fps-index* (modulo (+ *debug-fps-index* 1) sample-count))
    (when (< *debug-fps-count* sample-count)
      (set! *debug-fps-count* (+ *debug-fps-count* 1)))))

(define (rolling-fps)
  (if (or (= *debug-fps-count* 0)
          (<= *debug-fps-total* 0.0))
      0.0
      (/ *debug-fps-count* *debug-fps-total*)))

(define (one-decimal-string n)
  (let* ((scaled (inexact->exact (round (* n 10.0))))
         (whole (quotient scaled 10))
         (decimal (remainder scaled 10)))
    (format #f "~A.~A" whole decimal)))

(define (handle-debug-actions!)
  (toggle-debug-overlay!))

(define (draw-debug-overlay)
  (when (debug-visible?)
    (ensure-debug-font!)
    (let* ((font-size 18)
           (pad 10)
           (text (format #f "FPS ~A avg" (one-decimal-string (rolling-fps))))
           (panel-width (+ (measure-text text font-size) (* pad 2)))
           (panel-height 40)
           (x (- (get-screen-width) panel-width 8))
           (y 8))
      (draw-rectangle x y panel-width panel-height 10 12 14 210)
      (draw-rectangle-lines x y panel-width panel-height 120 220 170 255)
      (draw-debug-text text (+ x pad) (+ y 10) font-size 190 255 210 255))))

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
