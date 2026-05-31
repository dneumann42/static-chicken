;; ---------------------------------------------------------------------------
;; module-spec scanner — treats each source file as a module whose name is
;; derived from its path. The file body is read as top-level sexprs and later
;; wrapped as (module NAME * ...).

(define-record-type <module-spec>
  (make-module-spec path name forms imports)
  module-spec?
  (path module-spec-path)
  (name module-spec-name)
  (forms module-spec-forms)
  (imports module-spec-imports))

(define *module-specs* (make-hash-table equal?))
(define *module-paths* (make-hash-table eq?))

(define (string-suffix? suffix s)
  (let ((ls (string-length s))
        (lx (string-length suffix)))
    (and (>= ls lx)
         (string=? (substring s (- ls lx) ls) suffix))))

(define (relative-path-from root path)
  (let ((prefix (if (and (> (string-length root) 0)
                         (char=? (string-ref root (- (string-length root) 1)) #\/))
                    root
                    (string-append root "/"))))
    (if (and (>= (string-length path) (string-length prefix))
             (string=? (substring path 0 (string-length prefix)) prefix))
        (substring path (string-length prefix) (string-length path))
        path)))

(define (source-root-for-path path)
  (let loop ((dirs *watch-dirs*) (best #f))
    (cond
      ((null? dirs) best)
      (else
       (let ((root (app-path (car dirs))))
         (if (and (or (not best)
                      (> (string-length root) (string-length best)))
                  (let ((prefix (if (and (> (string-length root) 0)
                                         (char=? (string-ref root (- (string-length root) 1)) #\/))
                                    root
                                    (string-append root "/"))))
                    (and (>= (string-length path) (string-length prefix))
                         (string=? (substring path 0 (string-length prefix)) prefix))))
             (loop (cdr dirs) root)
             (loop (cdr dirs) best)))))))

(define (path-char->module-char c)
  (case c
    ((#\/ #\\ #\_) #\-)
    (else c)))

(define (source-path->module-name path)
  (let* ((root (source-root-for-path path))
         (rel (if root (relative-path-from root path) path))
         (stem (if (string-suffix? ".scm" rel)
                   (substring rel 0 (- (string-length rel) 4))
                   rel)))
    (string->symbol
     (list->string
      (map path-char->module-char (string->list stem))))))

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

(define (scan-module-spec path)
  (let ((forms (read-all-forms path))
        (name (source-path->module-name path)))
    (make-module-spec path
                      name
                      forms
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
         (hash-table-set! *module-paths* (module-spec-name spec) path)
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
  (enumerate-source-files))

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
