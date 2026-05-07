;; main.scm — opens a window and draws a rectangle, using raylib 6.0
;; Bindings inline (FFI through C shims so Color is rebuilt on the C side).

(import (chicken base)
        (chicken foreign))

(foreign-declare "#include \"raylib.h\"")

(foreign-declare #<<EOF
static void rl_clear_background(int r, int g, int b, int a) {
    Color c; c.r=(unsigned char)r; c.g=(unsigned char)g;
             c.b=(unsigned char)b; c.a=(unsigned char)a;
    ClearBackground(c);
}
static void rl_draw_rectangle(int x, int y, int w, int h,
                              int r, int g, int b, int a) {
    Color c; c.r=(unsigned char)r; c.g=(unsigned char)g;
             c.b=(unsigned char)b; c.a=(unsigned char)a;
    DrawRectangle(x, y, w, h, c);
}
EOF
)

(define init-window
  (foreign-lambda void "InitWindow" int int c-string))
(define close-window
  (foreign-lambda void "CloseWindow"))
(define window-should-close?
  (foreign-lambda bool "WindowShouldClose"))
(define begin-drawing
  (foreign-lambda void "BeginDrawing"))
(define end-drawing
  (foreign-lambda void "EndDrawing"))
(define set-target-fps
  (foreign-lambda void "SetTargetFPS" int))
(define clear-background
  (foreign-lambda void "rl_clear_background" int int int int))
(define draw-rectangle
  (foreign-lambda void "rl_draw_rectangle" int int int int int int int int))

(init-window 800 600 "static-chicken — raylib 6.0 software renderer")
(set-target-fps 60)

(let loop ()
  (unless (window-should-close?)
    (begin-drawing)
    (clear-background  30  30  40 255)
    (draw-rectangle 200 150 400 300 240 80 60 255)
    (end-drawing)
    (loop)))

(close-window)
