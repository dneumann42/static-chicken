;; Basic static-chicken example app.
;;
;; Run from the SDK root:
;;   STATIC_CHICKEN_APP_ROOT=examples/basic ./build.sh wayland
;;   STATIC_CHICKEN_APP_ROOT=examples/basic examples/basic/build/static-chicken/wayland/myapp
;;
;; Connect a live REPL while the app runs:
;;   rlwrap nc 127.0.0.1 1234

(once! 'window
       (lambda ()
         (init-window 800 600 "static-chicken - live")
         (set-target-fps 60)))

(set! *on-draw*
      (lambda ()
        (draw-rectangle 200 150 400 300 240 80 60 255)
        (draw-text "edit examples/basic/main.scm" 210 100 28 240 240 240 255)
        (draw-text "REPL: rlwrap nc localhost 1234" 260 470 18 180 180 200 255)))
