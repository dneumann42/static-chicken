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
