;; ---------------------------------------------------------------------------
;; module-spec scanner — parses each .scm file's top-level forms to extract
;; the (module NAME …) declarations and (import …) clauses so the loader
;; can compute a dependency graph and load files in topological order.

(define-record-type <module-spec>
  (make-module-spec path defines imports)
  module-spec?
  (path module-spec-path)
  (defines module-spec-defines)
  (imports module-spec-imports))

(define *module-specs* (make-hash-table equal?))

(define (read-all-forms path)
  (handle-exceptions _ '()
    (call-with-input-file path
      (lambda (port)
        (let loop ((acc '()))
          (let ((form (handle-exceptions _ #!eof (read port))))
            (if (eof-object? form)
                (reverse acc)
                (loop (cons form acc)))))))))

(define (import-clause-name spec acc)
  (cond
    ((symbol? spec) (cons spec acc))
    ((and (pair? spec)
          (pair? (cdr spec))
          (memq (car spec) '(only except prefix rename)))
     (import-clause-name (cadr spec) acc))
    (else acc)))

(define (collect-imports-in body acc)
  (let loop ((forms body) (acc acc))
    (cond
      ((null? forms) acc)
      ((not (pair? forms)) acc)
      (else
       (let ((form (car forms)))
         (cond
           ((and (pair? form) (eq? (car form) 'import))
            (loop (cdr forms) (fold import-clause-name acc (cdr form))))
           ((and (pair? form)
                 (memq (car form) '(module begin cond-expand)))
            (loop (cdr forms) (collect-imports-in (cdr form) acc)))
           (else (loop (cdr forms) acc))))))))

(define (collect-defines-in forms)
  (let loop ((forms forms) (acc '()))
    (cond
      ((null? forms) (reverse acc))
      ((and (pair? (car forms))
            (eq? (caar forms) 'module)
            (pair? (cdar forms))
            (symbol? (cadar forms)))
       (loop (cdr forms) (cons (cadar forms) acc)))
      ((and (pair? (car forms))
            (memq (caar forms) '(begin cond-expand)))
       (loop (cdr forms) (append (reverse (collect-defines-in (cdar forms))) acc)))
      (else (loop (cdr forms) acc)))))

(define (scan-module-spec path)
  (let ((forms (read-all-forms path)))
    (make-module-spec path
                      (collect-defines-in forms)
                      (reverse (collect-imports-in forms '())))))

(define (ensure-module-spec path)
  (let* ((cur (file-mtime-or-zero path))
         (cached (hash-table-ref/default *module-specs* path #f)))
    (cond
      ((and cached (= cur (vector-ref cached 0)))
       (vector-ref cached 1))
      (else
       (let ((spec (scan-module-spec path)))
         (hash-table-set! *module-specs* path (vector cur spec))
         spec)))))

;; ---------------------------------------------------------------------------
;; file watcher

(define *watch-mtimes* (make-hash-table equal?))
(define *loaded-once?* #f)

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
  (cond
    ((not *loaded-once?*)
     (let ((all (enumerate-watch-files)))
       (for-each
        (lambda (path)
          (hash-table-set! *watch-mtimes* path (file-mtime-or-zero path)))
        all)
       (load-in-order! all #f)
       (invalidate-watch-global-cache!)
       (request-watch-refresh!)
       (set! *loaded-once?* #t)))
    (else
     (let ((changed '()))
       (for-each
        (lambda (path)
          (let ((cur  (file-mtime-or-zero path))
                (prev (hash-table-ref/default *watch-mtimes* path 0)))
            (when (and (> cur 0) (not (= cur prev)))
              (hash-table-set! *watch-mtimes* path cur)
              (set! changed (cons path changed)))))
        (enumerate-watch-files))
       (unless (null? changed)
         (load-in-order! (expand-dependents changed) #t)
         (invalidate-watch-global-cache!)
         (request-watch-refresh!))))))
