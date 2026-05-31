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

(define (try-load-module spec)
  (handle-exceptions exn
    (cons #f (condition->runtime-error
              exn
              (format #f "load module ~A from ~A"
                      (module-spec-name spec)
                      (module-spec-path spec))))
    (eval `(module ,(module-spec-name spec) * ,@(module-spec-forms spec)))
    (cons #t #f)))

(define (safe-load! path)
  (let ((result (try-load path)))
    (if (car result)
        (clear-error!)
        (broadcast-error! (cdr result)))))

(define *debug-loads?*
  (let ((value (get-environment-variable "STATIC_CHICKEN_DEBUG_LOADS")))
    (and value
         (not (string=? value ""))
         (not (string=? value "0"))
         (not (string=? value "false")))))

(define *hotload-hook-module*
  (string->symbol (env/default "STATIC_CHICKEN_HOTLOAD_MODULE" "apothecary")))

(define (hook-procedure hook)
  (or (handle-exceptions _ #f (eval hook))
      (handle-exceptions _ #f
        (eval hook (module-environment *hotload-hook-module*)))))

(define (try-call-hook hook . args)
  (handle-exceptions exn
    (cons #f (condition->runtime-error exn (format #f "~A" hook)))
    (let ((proc (hook-procedure hook)))
      (if (procedure? proc)
          (cons #t (apply proc args))
          (cons #t #f)))))

(define (capture-hotload-state)
  (try-call-hook 'before-hotload!))

(define (restore-hotload-state! saved-state)
  (try-call-hook 'after-hotload! saved-state))

(define (topo-sort paths)
  ;; Order files so every module loads after the files that define modules
  ;; it imports. Ties broken by filename for determinism. On cycle, emit a
  ;; warning and append the SCC in filename order.
  (let* ((specs (map ensure-module-spec paths))
         (path-set (make-hash-table equal?))
         (name->path (make-hash-table eq?))
         (deps (make-hash-table equal?))
         (succ (make-hash-table equal?))
         (indeg (make-hash-table equal?)))
    (for-each (lambda (p) (hash-table-set! path-set p #t)) paths)
    (for-each
     (lambda (s)
       (hash-table-set! name->path (module-spec-name s) (module-spec-path s)))
     specs)
    (for-each
     (lambda (s)
       (let* ((self (module-spec-path s))
              (ds (filter
                   (lambda (p)
                     (and p
                          (not (string=? p self))
                          (hash-table-exists? path-set p)))
                   (map (lambda (n) (hash-table-ref/default name->path n #f))
                        (module-spec-imports s)))))
         (hash-table-set! deps self (delete-duplicates ds string=?))))
     specs)
    (for-each
     (lambda (p)
       (hash-table-set! indeg p 0)
       (hash-table-set! succ p '()))
     paths)
    (for-each
     (lambda (p)
       (for-each
        (lambda (d)
          (hash-table-set! succ d (cons p (hash-table-ref/default succ d '())))
          (hash-table-set! indeg p (+ 1 (hash-table-ref/default indeg p 0))))
        (hash-table-ref/default deps p '())))
     paths)
    (let loop ((ready (sort (filter (lambda (p) (= 0 (hash-table-ref indeg p))) paths)
                            string<?))
               (out '()))
      (cond
        ((null? ready)
         (let ((leftover (filter (lambda (p) (> (hash-table-ref indeg p) 0)) paths)))
           (when (pair? leftover)
             (print "[warn] import cycle among: " (sort leftover string<?))
             (flush-output))
           (append (reverse out) (sort leftover string<?))))
        (else
         (let* ((p (car ready)))
           (for-each
            (lambda (s)
              (hash-table-set! indeg s (- (hash-table-ref indeg s) 1)))
            (hash-table-ref/default succ p '()))
           (let ((freed
                  (filter (lambda (s) (= 0 (hash-table-ref indeg s)))
                          (hash-table-ref/default succ p '()))))
             (loop (sort (append freed (cdr ready)) string<?)
                   (cons p out)))))))))

(define (expand-dependents changed)
  ;; Given a list of changed paths, return them plus every path whose
  ;; module transitively imports a module defined by something in that
  ;; list (over the full watch set).
  (let* ((all (enumerate-watch-files))
         (specs (map ensure-module-spec all))
         (path-set (make-hash-table equal?))
         (name->path (make-hash-table eq?))
         (rev (make-hash-table equal?))
         (visited (make-hash-table equal?)))
    (for-each (lambda (p) (hash-table-set! path-set p #t)) all)
    (for-each
     (lambda (s)
       (hash-table-set! name->path (module-spec-name s) (module-spec-path s)))
     specs)
    (for-each
     (lambda (s)
       (let ((f (module-spec-path s)))
         (for-each
          (lambda (name)
            (let ((g (hash-table-ref/default name->path name #f)))
              (when (and g (not (string=? g f)) (hash-table-exists? path-set g))
                (hash-table-set! rev g
                                 (cons f (hash-table-ref/default rev g '()))))))
          (module-spec-imports s))))
     specs)
    (let loop ((stack changed))
      (cond
        ((null? stack) #f)
        ((hash-table-exists? visited (car stack))
         (loop (cdr stack)))
        (else
         (hash-table-set! visited (car stack) #t)
         (loop (append (hash-table-ref/default rev (car stack) '())
                       (cdr stack))))))
    (hash-table-keys visited)))

(define (load-in-order! paths announce-reload?)
  (let ((ordered (topo-sort paths))
        (saved-state-result (and announce-reload? (capture-hotload-state))))
    (clear-error!)
    (let ((loaded?
           (let loop ((paths ordered))
             (cond
              ((null? paths) #t)
              (else
	       (let ((path (car paths)))
	         (when announce-reload?
	           (print "[reload] " path)
	           (flush-output))
	         (when *debug-loads?*
	           (print "[load] " path)
	           (flush-output))
	         (let ((result (try-load-module (ensure-module-spec path))))
	           (if (car result)
		       (loop (cdr paths))
		       (begin
                         (broadcast-error! (cdr result))
                         #f)))))))))
      (when (and announce-reload? saved-state-result (car saved-state-result))
        (let ((restore-result (restore-hotload-state! (cdr saved-state-result))))
          (unless (car restore-result)
            (broadcast-error! (cdr restore-result)))))
      loaded?)))
