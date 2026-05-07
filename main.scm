;; main.scm — user code, hot-reloaded.
;;
;; Edit this file (or anything under src/, plugins/) and save — the running
;; binary picks up the change next frame. No restart.
;;
;; Connect a live REPL while the app runs (it eval's against the same image):
;;   rlwrap nc 127.0.0.1 1234
;;
;; State preservation pattern (CL-defvar style — only initialises once):
;;   (once! '*world* (lambda () (set! *world* (initial-world))))
;; Plain (define x ...) re-executes on every reload, like CL `defparameter`.

(once! 'window
       (lambda ()
         (init-window 800 600 "static-chicken — live")
         (set-target-fps 60)))

(set! *on-frame*
      (lambda ()
        (draw-rectangle 200 150 400 300 240 80 60 255)
        (draw-text "edit main.scm — hot-reload" 200 100 28 240 240 240 255)
        (draw-text "REPL: rlwrap nc localhost 1234" 200 470 18 180 180 200 255)))
