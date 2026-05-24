(module static-chicken-math
  (vec2
   vec2-x
   vec2-y
   vec2+
   vec2*
   vec2-length
   vec2-normalize
   vec2-limit)

(import scheme)

(define (vec2 x y)
  (list x y))

(define (vec2-x v)
  (car v))

(define (vec2-y v)
  (cadr v))

(define (vec2+ a b)
  (vec2 (+ (vec2-x a) (vec2-x b))
        (+ (vec2-y a) (vec2-y b))))

(define (vec2* v scalar)
  (vec2 (* (vec2-x v) scalar)
        (* (vec2-y v) scalar)))

(define (vec2-length v)
  (sqrt (+ (* (vec2-x v) (vec2-x v))
           (* (vec2-y v) (vec2-y v)))))

(define (vec2-normalize v)
  (let ((length (vec2-length v)))
    (if (> length 0.0)
        (vec2 (/ (vec2-x v) length)
              (/ (vec2-y v) length))
        (vec2 0.0 0.0))))

(define (vec2-limit v max-length)
  (let ((length (vec2-length v)))
    (if (> length max-length)
        (vec2* (vec2-normalize v) max-length)
        v)))
)
