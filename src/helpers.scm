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
