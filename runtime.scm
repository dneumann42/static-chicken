;; runtime.scm — the static-chicken host. Compiled into the binary.
;;
;; Responsibilities:
;;   * spawn a TCP REPL server (sexp-over-TCP, 127.0.0.1:$REPL_PORT)
;;   * load main.scm + every .scm under src/ and plugins/, recursively
;;   * watch them; reload on mtime change
;;   * dispatch *on-frame* every frame, catch errors
;;   * broadcast errors to the on-screen overlay, stderr, and every REPL client
;;
;; Anything user code can call (init-window, draw-rectangle, ...) lives in
;; raylib.scm (also baked in). User-facing globals introduced here:
;;   *on-frame*       thunk run every frame
;;   *last-error*     #f or string
;;   once! KEY THUNK  CL-defvar-style idempotent init

(declare (uses raylib))

(import (chicken base) (chicken eval) (chicken load)
        (chicken file) (chicken file.posix)
        (chicken tcp)
        (chicken condition) (chicken format)
        (chicken process-context) (chicken port)
        (chicken string) (chicken sort)
        (srfi 1) (srfi 18) (srfi 69))

;; ---------------------------------------------------------------------------
;; user-facing globals

(define *on-frame*     (lambda () #f))
(define *last-error*   #f)
(define *repl-clients* '())

(define *once-keys* (make-hash-table))
(define (once! key thunk)
  (unless (hash-table-exists? *once-keys* key)
    (hash-table-set! *once-keys* key #t)
    (thunk)))

;; ---------------------------------------------------------------------------
;; configuration

(define *app-entry*  "main.scm")
(define *watch-dirs* '("src" "plugins"))

(define *repl-host* "127.0.0.1")
(define *repl-port*
  (or (and-let* ((s (get-environment-variable "REPL_PORT"))
                 (n (string->number s)))
        n)
      1234))

;; ---------------------------------------------------------------------------
;; condition formatting

(define exn-message
  (condition-property-accessor 'exn 'message #f))
(define exn-location
  (condition-property-accessor 'exn 'location #f))
(define exn-arguments
  (condition-property-accessor 'exn 'arguments '()))

(define (condition->string exn)
  (cond
    ((condition? exn)
     (let ((msg (or (exn-message exn) "(no message)"))
           (loc (exn-location exn))
           (args (exn-arguments exn)))
       (format #f "~A~A~A"
               (if loc (format #f "[~A] " loc) "")
               msg
               (if (pair? args) (format #f ": ~S" args) ""))))
    (else
     (format #f "~A" exn))))

;; ---------------------------------------------------------------------------
;; error broadcast (overlay + stderr + every REPL client)

(define (broadcast-error! str)
  (set! *last-error* str)
  ;; stderr
  (with-output-to-port (current-error-port)
    (lambda () (print "[error] " str)))
  ;; REPL clients — drop dead ones
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
         *repl-clients*)))

(define (clear-error!) (set! *last-error* #f))

;; ---------------------------------------------------------------------------
;; safe wrappers

(define (safe-call! thunk)
  (handle-exceptions exn
    (broadcast-error! (condition->string exn))
    (thunk)))

(define (safe-load! path)
  (handle-exceptions exn
    (broadcast-error! (format #f "load ~A: ~A" path (condition->string exn)))
    (load path)
    (clear-error!)))

;; ---------------------------------------------------------------------------
;; file watcher

(define *watch-mtimes* (make-hash-table equal?))

(define (scm-file? path)
  (let ((p (if (string? path) path (->string path)))
        (suf ".scm"))
    (let ((lp (string-length p)) (ls (string-length suf)))
      (and (>= lp ls)
           (string=? (substring p (- lp ls) lp) suf)))))

(define (enumerate-watch-files)
  (let ((files (if (file-exists? *app-entry*) (list *app-entry*) '())))
    (for-each
     (lambda (dir)
       (when (and (file-exists? dir) (directory? dir))
         (set! files
               (append (find-files dir test: scm-file?) files))))
     *watch-dirs*)
    (sort (delete-duplicates files string=?) string<?)))

(define (file-mtime-or-zero path)
  (handle-exceptions _ 0 (file-modification-time path)))

(define (check-watches!)
  (for-each
   (lambda (path)
     (let ((cur  (file-mtime-or-zero path))
           (prev (hash-table-ref/default *watch-mtimes* path 0)))
       (when (and (> cur 0) (not (= cur prev)))
         (hash-table-set! *watch-mtimes* path cur)
         (when (> prev 0)
           (print "[reload] " path)
           (flush-output))
         (safe-load! path))))
   (enumerate-watch-files)))

;; ---------------------------------------------------------------------------
;; on-screen error overlay

(define (split-lines s)
  (string-split s "\n" #t))

(define (draw-error-overlay msg)
  (let line-loop ((ls (split-lines msg)) (y 8))
    (when (pair? ls)
      (draw-rectangle 0 y 4096 22 0 0 0 200)
      (draw-text (car ls) 8 (+ y 2) 18 255 90 90 255)
      (line-loop (cdr ls) (+ y 22)))))

;; ---------------------------------------------------------------------------
;; TCP REPL

(define *repl-listener* #f)

(define (start-repl-server!)
  (handle-exceptions exn
    (fprintf (current-error-port)
             "[repl] could not bind ~A:~A — ~A~%"
             *repl-host* *repl-port* (condition->string exn))
    (set! *repl-listener* (tcp-listen *repl-port* 4 *repl-host*))
    (fprintf (current-error-port)
             "[repl] listening on ~A:~A~%"
             *repl-host* *repl-port*)))

;; Polled from the frame loop. Single-thread design: poll for new connections
;; and per-client readability with tcp-accept-ready? / char-ready?, so we never
;; block on I/O. The frame loop drives everything.
(define *repl-conns* '())   ; ((in out partial) ...)

(define (poll-repl-accept!)
  (when (and *repl-listener*
             (handle-exceptions _ #f (tcp-accept-ready? *repl-listener*)))
    (handle-exceptions exn
      (fprintf (current-error-port)
               "[repl] accept failed: ~A~%"
               (condition->string exn))
      (receive (in out) (tcp-accept *repl-listener*)
        (display ";; static-chicken REPL — eval shares the live image.\n" out)
        (display ";; type Ctrl-D or ,quit to disconnect.\n> " out)
        (flush-output out)
        (set! *repl-clients* (cons out *repl-clients*))
        (set! *repl-conns* (cons (list in out) *repl-conns*))))))

(define (drop-conn! out)
  (set! *repl-clients*
        (filter (lambda (p) (not (eq? p out))) *repl-clients*)))

(define (handle-conn! in out)
  ;; Returns #t if the connection should remain in the active set, #f to drop.
  (cond
    ((not (handle-exceptions _ #f (char-ready? in)))
     #t)                                   ; idle — keep
    (else
     (handle-exceptions exn
       (begin
         (display "[error] " out)
         (display (condition->string exn) out)
         (display "\n> " out)
         (flush-output out)
         #t)
       (let ((expr (read in)))
         (cond
           ((or (eof-object? expr) (equal? expr ',quit))
            (drop-conn! out)
            (handle-exceptions _ #f (close-input-port in))
            (handle-exceptions _ #f (close-output-port out))
            #f)
           (else
            (let ((result (eval expr (interaction-environment))))
              (write result out)
              (display "\n> " out)
              (flush-output out)
              #t))))))))

(define (poll-repl-input!)
  (set! *repl-conns*
        (filter (lambda (c) (handle-conn! (car c) (cadr c)))
                *repl-conns*)))

;; ---------------------------------------------------------------------------
;; main

(define (frame!)
  (poll-repl-accept!)
  (poll-repl-input!)
  (check-watches!)
  (cond
    ((not (is-window-ready?))
     (thread-sleep! 0.05))
    ((window-should-close?)
     #f)
    (else
     (begin-drawing)
     (clear-background 30 30 40 255)
     (safe-call! *on-frame*)
     (when *last-error* (draw-error-overlay *last-error*))
     (end-drawing)))
  (thread-yield!))

(define (main)
  (start-repl-server!)
  (check-watches!)
  (let loop ()
    (frame!)
    (cond
      ((and (is-window-ready?) (window-should-close?))
       (close-window))
      (else
       (loop)))))

(main)
