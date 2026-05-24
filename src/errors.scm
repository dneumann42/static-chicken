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

(define (format-condition-message msg args)
  (cond
    ((and (string=? msg "unbound variable")
          (pair? args)
          (symbol? (car args)))
     (format #f "unbound variable: ~A" (car args)))
    ((pair? args)
     (format #f "~A: ~S" msg args))
    (else
     msg)))

(define (condition->runtime-error exn context)
  (cond
    ((condition? exn)
     (let* ((msg (or (exn-message exn) "(no message)"))
            (loc (exn-location exn))
            (args (exn-arguments exn))
            (chain (exn-call-chain exn))
            (source (or (call-chain-location chain)
                        (and loc (->display-string loc))))
            (formatted-msg (format-condition-message msg args))
            (text (format #f "~A~A~A"
                          (if context (format #f "~A: " context) "")
                          (if source (format #f "~A: " source) "")
                          formatted-msg)))
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
