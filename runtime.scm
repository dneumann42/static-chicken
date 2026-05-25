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
        (chicken memory representation)
        (chicken tcp)
        (chicken condition) (chicken format)
        (chicken pretty-print)
        (chicken process) (chicken process-context) (chicken port)
        (chicken string) (chicken sort)
        (srfi 1) (srfi 9) (srfi 18) (srfi 69)
        raylib
        apropos-api
        matchable miscmacros record-variants coops coops-primitive-objects)

(define *on-draw*     (lambda () #f))
(define *on-update*   (lambda () #f))
(define *last-error*   #f)
(define *last-error-text* #f)
(define *error-expanded?* #f)
(define *repl-clients* '())
(define *stdout-port* (current-output-port))
(define *stdout-log-installed?* #f)
(define *log-lines* '())
(define *log-partial* "")
(define *log-visible?* #f)
(define *log-scroll* 0)
(define *debug-visible?* #f)
(define *debug-fps-samples* (make-vector 60 0.0))
(define *debug-fps-index* 0)
(define *debug-fps-count* 0)
(define *debug-fps-total* 0.0)
(define *watch-visible?* #f)
(define *watch-input* "")
(define *watch-global-scroll* 0)
(define *watch-global-cache* #f)
(define *watch-next-id* 1)
(define *pinned-watches* '())

(define *once-keys* (make-hash-table))
(define (once! key thunk)
  (unless (hash-table-exists? *once-keys* key)
    (hash-table-set! *once-keys* key #t)
    (thunk)))

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

(define *log-max-lines*
  (or (and-let* ((s (get-environment-variable "STATIC_CHICKEN_LOG_LINES"))
                 (n (string->number s)))
        n)
      200))

(define *watch-dirs*
  (filter (lambda (s) (not (string=? s "")))
          (string-split (env/default "STATIC_CHICKEN_WATCH_DIRS" "src:plugins")
                        ":")))

(define *watch-enabled?*
  (let ((value (get-environment-variable "STATIC_CHICKEN_WATCH")))
    (and value
         (not (string=? value ""))
         (not (string=? value "0"))
         (not (string=? value "false")))))

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

(define (load-runtime-import-library! path)
  (let ((full-path (app-path path)))
    (if (file-exists? full-path)
        (load full-path)
        (error "missing runtime import library" full-path))))

(define (load-runtime-import-libraries!)
  (for-each
   load-runtime-import-library!
   '("vendor/static-chicken/raylib.import.scm"
     "vendor/static-chicken/matchable.import.scm"
     "vendor/static-chicken/miscmacros.import.scm"
     "vendor/static-chicken/record-variants.import.scm"
     "vendor/static-chicken/coops.import.scm"
     "vendor/static-chicken/coops-primitive-objects.import.scm"
     "vendor/static-chicken/apropos-api.import.scm")))

(include "src/errors.scm")
(include "src/log-capture.scm")
(include "src/math.scm")
(include "src/watch.scm")
(include "src/loader.scm")
(include "src/module-spec.scm")
(include "src/overlays.scm")
(include "src/repl.scm")
(include "src/helpers.scm")

(define (frame!)
  (poll-repl-accept!)
  (poll-repl-input!)
  (when *watch-enabled?* (check-watches!))
  (cond
   ((not (is-window-ready?))
    (thread-sleep! 0.05))
   ((window-should-close?)
    #f)
   (else
    (when *last-error* (toggle-error-expanded!))
    (when *last-error* (handle-error-actions! *last-error*))
    (update-debug-frame!)
    (handle-debug-actions!)
    (handle-log-actions!)
    (handle-watch-panel-actions!)
    (safe-call! *on-update*)
    (update-pinned-watches!)
    (handle-pinned-watch-actions!)
    (begin-drawing)
    (clear-background (make-color 30 30 40))
    (safe-call! *on-draw*)
    (draw-debug-overlay)
    (draw-pinned-watches)
    (draw-log-overlay)
    (draw-watch-panel)
    (when *last-error* (draw-error-overlay *last-error*))
    (end-drawing)))
  (thread-yield!))

(define (main)
  (install-stdout-log!)
  (start-repl-server!)
  (install-helper-syntax!)
  (load-runtime-import-libraries!)
  (check-watches!)
  (let loop ()
    (frame!)
    (cond
      ((and (is-window-ready?) (window-should-close?))
       (close-window))
      (else
       (loop)))))

(main)
