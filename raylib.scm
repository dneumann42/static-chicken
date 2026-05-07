;; raylib.scm — minimal CHICKEN 5 FFI bindings for raylib 6.0.
;; Color is passed as four ints (r g b a) and rebuilt inside small C shims to
;; dodge struct-by-value FFI quirks.
;;
;; Compiled as a separate unit and linked into the final binary.

(declare (unit raylib))

(import (chicken foreign))

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
  (foreign-lambda void "rl_draw_rectangle"
                  int int int int int int int int))
