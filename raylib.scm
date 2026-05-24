;; raylib.scm — CHICKEN 5 FFI bindings for raylib 6.0.
;;
;; Structs are kept behind small C shims where CHICKEN's FFI would otherwise
;; need to pass C structs by value. The public Scheme API exposes native
;; records and constants instead.
;;
;; Compiled as a separate unit and linked into the final binary.

(declare (unit raylib))

(module raylib *

(import scheme (chicken base) (chicken foreign) (srfi 1) (srfi 9))

(foreign-declare "#include \"raylib.h\"")
(foreign-declare "#include <string.h>")

(foreign-declare #<<EOF
static Font rl_loaded_font = { 0 };
static Font rl_debug_font = { 0 };

static Color rl_color(int r, int g, int b, int a) {
    Color c;
    c.r = (unsigned char)r;
    c.g = (unsigned char)g;
    c.b = (unsigned char)b;
    c.a = (unsigned char)a;
    return c;
}

int rl_load_font(const char *path, int fontSize) {
    if (rl_loaded_font.texture.id != 0) {
        UnloadFont(rl_loaded_font);
        rl_loaded_font = (Font){ 0 };
    }
    rl_loaded_font = LoadFontEx(path, fontSize, NULL, 0);
    if (rl_loaded_font.texture.id != 0) {
        SetTextureFilter(rl_loaded_font.texture, TEXTURE_FILTER_BILINEAR);
        return 1;
    }
    return 0;
}

int rl_load_debug_font(const char *path, int fontSize) {
    if (rl_debug_font.texture.id != 0) {
        UnloadFont(rl_debug_font);
        rl_debug_font = (Font){ 0 };
    }
    rl_debug_font = LoadFontEx(path, fontSize, NULL, 0);
    if (rl_debug_font.texture.id != 0) {
        SetTextureFilter(rl_debug_font.texture, TEXTURE_FILTER_BILINEAR);
        return 1;
    }
    return 0;
}

static void rl_clear_background(int r, int g, int b, int a) {
    ClearBackground(rl_color(r, g, b, a));
}
static void rl_draw_rectangle(int x, int y, int w, int h,
                              int r, int g, int b, int a) {
    DrawRectangle(x, y, w, h, rl_color(r, g, b, a));
}
static void rl_draw_rectangle_lines(int x, int y, int w, int h,
                                    int r, int g, int b, int a) {
    DrawRectangleLines(x, y, w, h, rl_color(r, g, b, a));
}
static void rl_draw_rectangle_gradient_v(int x, int y, int w, int h,
                                         int r1, int g1, int b1, int a1,
                                         int r2, int g2, int b2, int a2) {
    DrawRectangleGradientV(x, y, w, h,
                           rl_color(r1, g1, b1, a1),
                           rl_color(r2, g2, b2, a2));
}
static void rl_draw_pixel(int x, int y, int r, int g, int b, int a) {
    DrawPixel(x, y, rl_color(r, g, b, a));
}
static void rl_draw_line(int x1, int y1, int x2, int y2,
                         int r, int g, int b, int a) {
    DrawLine(x1, y1, x2, y2, rl_color(r, g, b, a));
}
static void rl_draw_line_ex(float x1, float y1, float x2, float y2,
                            float thick, int r, int g, int b, int a) {
    Vector2 start = { x1, y1 };
    Vector2 end = { x2, y2 };
    DrawLineEx(start, end, thick, rl_color(r, g, b, a));
}
static void rl_draw_circle(int x, int y, float radius,
                           int r, int g, int b, int a) {
    DrawCircle(x, y, radius, rl_color(r, g, b, a));
}
static void rl_draw_circle_lines(int x, int y, float radius,
                                 int r, int g, int b, int a) {
    DrawCircleLines(x, y, radius, rl_color(r, g, b, a));
}
static void rl_draw_text(const char *txt, int x, int y, int sz,
                         int r, int g, int b, int a) {
    Color c = rl_color(r, g, b, a);
    if (rl_loaded_font.texture.id != 0) {
        Vector2 pos = { (float)x, (float)y };
        DrawTextEx(rl_loaded_font, txt, pos, (float)sz, 1.0f, c);
    } else {
        DrawText(txt, x, y, sz, c);
    }
}
static void rl_draw_text_ex(const char *txt, float x, float y, float sz,
                            float spacing, int r, int g, int b, int a) {
    Color c = rl_color(r, g, b, a);
    if (rl_loaded_font.texture.id != 0) {
        Vector2 pos = { x, y };
        DrawTextEx(rl_loaded_font, txt, pos, sz, spacing, c);
    } else {
        DrawText(txt, (int)x, (int)y, (int)sz, c);
    }
}
static void rl_draw_debug_text(const char *txt, int x, int y, int sz,
                               int r, int g, int b, int a) {
    Color c = rl_color(r, g, b, a);
    if (rl_debug_font.texture.id != 0) {
        Vector2 pos = { (float)x, (float)y };
        DrawTextEx(rl_debug_font, txt, pos, (float)sz, 1.0f, c);
    } else {
        DrawText(txt, x, y, sz, c);
    }
}
static int rl_measure_text(const char *txt, int fontSize) {
    if (rl_loaded_font.texture.id != 0) {
        Vector2 sz = MeasureTextEx(rl_loaded_font, txt, (float)fontSize, 1.0f);
        return (int)sz.x;
    }
    return MeasureText(txt, fontSize);
}
static const char *rl_get_text_input(void) {
    static char buf[4096];
    int len = 0;
    int codepoint = GetCharPressed();

    buf[0] = '\0';
    while (codepoint != 0) {
        int bytes = 0;
        if ((codepoint >= 32) && (codepoint != 127)) {
            const char *utf8 = CodepointToUTF8(codepoint, &bytes);
            if (utf8 != NULL && bytes > 0 && len + bytes < (int)sizeof(buf)) {
                memcpy(buf + len, utf8, (size_t)bytes);
                len += bytes;
                buf[len] = '\0';
            }
        }
        codepoint = GetCharPressed();
    }

    return buf;
}

static void rl_set_texture_filter(unsigned int id, int filter) {
    Texture2D tex = { id, 0, 0, 0, 0 };
    SetTextureFilter(tex, filter);
}

static float rl_get_window_scale_dpi_x(void) {
    Vector2 dpi = GetWindowScaleDPI();
    return dpi.x;
}
EOF
)

;; ---------------------------------------------------------------------------
;; Scheme colors

(define-record-type <color>
  (%make-color r g b a)
  color?
  (r color-r)
  (g color-g)
  (b color-b)
  (a color-a))

(define (clamp-byte n)
  (let ((v (inexact->exact (truncate n))))
    (cond
      ((< v 0) 0)
      ((> v 255) 255)
      (else v))))

(define (make-color r g b . rest)
  (%make-color (clamp-byte r)
               (clamp-byte g)
               (clamp-byte b)
               (clamp-byte (if (null? rest) 255 (car rest)))))

(define color-rgba make-color)

(define (color-rgb r g b)
  (make-color r g b 255))

(define (color->list c)
  (list (color-r c) (color-g c) (color-b c) (color-a c)))

(define (color-with-alpha c a)
  (let ((c (->color c)))
    (make-color (color-r c) (color-g c) (color-b c) a)))

(define (color-fade c alpha)
  (color-with-alpha c (* 255 alpha)))

(define color-lightgray  (make-color 200 200 200 255))
(define color-gray       (make-color 130 130 130 255))
(define color-darkgray   (make-color 80 80 80 255))
(define color-yellow     (make-color 253 249 0 255))
(define color-gold       (make-color 255 203 0 255))
(define color-orange     (make-color 255 161 0 255))
(define color-pink       (make-color 255 109 194 255))
(define color-red        (make-color 230 41 55 255))
(define color-maroon     (make-color 190 33 55 255))
(define color-green      (make-color 0 228 48 255))
(define color-lime       (make-color 0 158 47 255))
(define color-darkgreen  (make-color 0 117 44 255))
(define color-skyblue    (make-color 102 191 255 255))
(define color-blue       (make-color 0 121 241 255))
(define color-darkblue   (make-color 0 82 172 255))
(define color-purple     (make-color 200 122 255 255))
(define color-violet     (make-color 135 60 190 255))
(define color-darkpurple (make-color 112 31 126 255))
(define color-beige      (make-color 211 176 131 255))
(define color-brown      (make-color 127 106 79 255))
(define color-darkbrown  (make-color 76 63 47 255))
(define color-white      (make-color 255 255 255 255))
(define color-black      (make-color 0 0 0 255))
(define color-blank      (make-color 0 0 0 0))
(define color-magenta    (make-color 255 0 255 255))
(define color-raywhite   (make-color 245 245 245 255))
(define color-tomato     (make-color 240 80 60 255))

(define color-palette
  `((lightgray . ,color-lightgray)
    (gray . ,color-gray)
    (darkgray . ,color-darkgray)
    (yellow . ,color-yellow)
    (gold . ,color-gold)
    (orange . ,color-orange)
    (pink . ,color-pink)
    (red . ,color-red)
    (maroon . ,color-maroon)
    (green . ,color-green)
    (lime . ,color-lime)
    (darkgreen . ,color-darkgreen)
    (skyblue . ,color-skyblue)
    (blue . ,color-blue)
    (darkblue . ,color-darkblue)
    (purple . ,color-purple)
    (violet . ,color-violet)
    (darkpurple . ,color-darkpurple)
    (beige . ,color-beige)
    (brown . ,color-brown)
    (darkbrown . ,color-darkbrown)
    (white . ,color-white)
    (black . ,color-black)
    (blank . ,color-blank)
    (magenta . ,color-magenta)
    (raywhite . ,color-raywhite)
    (tomato . ,color-tomato)))

(define (palette-ref name)
  (let ((found (assq name color-palette)))
    (if found
        (cdr found)
        (error 'palette-ref "unknown palette color" name))))

(define (->color value)
  (cond
    ((color? value) value)
    ((symbol? value) (palette-ref value))
    ((and (list? value)
          (or (= (length value) 3) (= (length value) 4)))
     (apply make-color value))
    (else
     (error '->color "expected color, palette symbol, or RGB/RGBA list" value))))

(define (call-with-color proc fixed color)
  (apply proc (append fixed (color->list (->color color)))))

(define (call-with-two-colors proc fixed color-a color-b)
  (apply proc (append fixed
                      (color->list (->color color-a))
                      (color->list (->color color-b)))))

(define (bad-arity name args)
  (error name "expected a color argument or raw RGBA components" args))

(define key-null 0)
(define key-space 32)
(define key-apostrophe 39)
(define key-comma 44)
(define key-minus 45)
(define key-period 46)
(define key-slash 47)
(define key-zero 48)
(define key-one 49)
(define key-two 50)
(define key-three 51)
(define key-four 52)
(define key-five 53)
(define key-six 54)
(define key-seven 55)
(define key-eight 56)
(define key-nine 57)
(define key-semicolon 59)
(define key-equal 61)
(define key-a 65)
(define key-b 66)
(define key-c 67)
(define key-d 68)
(define key-e 69)
(define key-f 70)
(define key-g 71)
(define key-h 72)
(define key-i 73)
(define key-j 74)
(define key-k 75)
(define key-l 76)
(define key-m 77)
(define key-n 78)
(define key-o 79)
(define key-p 80)
(define key-q 81)
(define key-r 82)
(define key-s 83)
(define key-t 84)
(define key-u 85)
(define key-v 86)
(define key-w 87)
(define key-x 88)
(define key-y 89)
(define key-z 90)
(define key-left-bracket 91)
(define key-backslash 92)
(define key-right-bracket 93)
(define key-grave 96)
(define key-escape 256)
(define key-enter 257)
(define key-tab 258)
(define key-backspace 259)
(define key-insert 260)
(define key-delete 261)
(define key-right 262)
(define key-left 263)
(define key-down 264)
(define key-up 265)
(define key-page-up 266)
(define key-page-down 267)
(define key-home 268)
(define key-end 269)
(define key-caps-lock 280)
(define key-scroll-lock 281)
(define key-num-lock 282)
(define key-print-screen 283)
(define key-pause 284)
(define key-f1 290)
(define key-f2 291)
(define key-f3 292)
(define key-f4 293)
(define key-f5 294)
(define key-f6 295)
(define key-f7 296)
(define key-f8 297)
(define key-f9 298)
(define key-f10 299)
(define key-f11 300)
(define key-f12 301)
(define key-left-shift 340)
(define key-left-control 341)
(define key-left-alt 342)
(define key-left-super 343)
(define key-right-shift 344)
(define key-right-control 345)
(define key-right-alt 346)
(define key-right-super 347)
(define key-kb-menu 348)
(define mouse-button-left 0)
(define mouse-button-right 1)
(define mouse-button-middle 2)
(define mouse-button-side 3)
(define mouse-button-extra 4)
(define mouse-button-forward 5)
(define mouse-button-back 6)

(define texture-filter-point 0)
(define texture-filter-bilinear 1)
(define texture-filter-trilinear 2)
(define texture-filter-anisotropic-4x 3)
(define texture-filter-anisotropic-8x 4)
(define texture-filter-anisotropic-16x 5)

(define flag-vsync-hint #x00000040)
(define flag-fullscreen-mode #x00000002)
(define flag-window-resizable #x00000004)
(define flag-window-undecorated #x00000008)
(define flag-window-hidden #x00000080)
(define flag-window-minimized #x00000200)
(define flag-window-maximized #x00000400)
(define flag-window-unfocused #x00000800)
(define flag-window-topmost #x00001000)
(define flag-window-always-run #x00000100)
(define flag-window-transparent #x00000010)
(define flag-window-highdpi #x00002000)
(define flag-window-mouse-passthrough #x00004000)
(define flag-borderless-windowed-mode #x00008000)
(define flag-msaa-4x-hint #x00000020)
(define flag-interlaced-hint #x00010000)

(define init-window
  (foreign-lambda void "InitWindow" int int c-string))

(define close-window
  (foreign-lambda void "CloseWindow"))

(define get-screen-width
  (foreign-lambda int "GetScreenWidth"))

(define get-screen-height
  (foreign-lambda int "GetScreenHeight"))

(define window-should-close?
  (foreign-lambda bool "WindowShouldClose"))

(define begin-drawing
  (foreign-lambda void "BeginDrawing"))

(define end-drawing
  (foreign-lambda void "EndDrawing"))

(define set-target-fps
  (foreign-lambda void "SetTargetFPS" int))

(define set-exit-key
  (foreign-lambda void "SetExitKey" int))

(define %clear-background-rgba
  (foreign-lambda void "rl_clear_background" int int int int))

(define %draw-rectangle-rgba
  (foreign-lambda void "rl_draw_rectangle"
                  int int int int int int int int))

(define %draw-rectangle-lines-rgba
  (foreign-lambda void "rl_draw_rectangle_lines"
                  int int int int int int int int))

(define %draw-rectangle-gradient-v-rgba
  (foreign-lambda void "rl_draw_rectangle_gradient_v"
                  int int int int int int int int int int int int))

(define %draw-pixel-rgba
  (foreign-lambda void "rl_draw_pixel"
                  int int int int int int))

(define %draw-line-rgba
  (foreign-lambda void "rl_draw_line"
                  int int int int int int int int))

(define %draw-line-ex-rgba
  (foreign-lambda void "rl_draw_line_ex"
                  float float float float float int int int int))

(define %draw-circle-rgba
  (foreign-lambda void "rl_draw_circle"
                  int int float int int int int))

(define %draw-circle-lines-rgba
  (foreign-lambda void "rl_draw_circle_lines"
                  int int float int int int int))

(define %draw-text-rgba
  (foreign-lambda void "rl_draw_text"
                  c-string int int int int int int int))

(define %draw-text-ex-rgba
  (foreign-lambda void "rl_draw_text_ex"
                  c-string float float float float int int int int))

(define %draw-debug-text-rgba
  (foreign-lambda void "rl_draw_debug_text"
                  c-string int int int int int int int))

(define (clear-background . args)
  (case (length args)
    ((1) (call-with-color %clear-background-rgba '() (car args)))
    ((4) (apply %clear-background-rgba args))
    (else (bad-arity 'clear-background args))))

(define (draw-pixel . args)
  (case (length args)
    ((3) (call-with-color %draw-pixel-rgba (take args 2) (list-ref args 2)))
    ((6) (apply %draw-pixel-rgba args))
    (else (bad-arity 'draw-pixel args))))

(define (draw-line . args)
  (case (length args)
    ((5) (call-with-color %draw-line-rgba (take args 4) (list-ref args 4)))
    ((8) (apply %draw-line-rgba args))
    (else (bad-arity 'draw-line args))))

(define (draw-line-ex . args)
  (case (length args)
    ((6) (call-with-color %draw-line-ex-rgba (take args 5) (list-ref args 5)))
    ((9) (apply %draw-line-ex-rgba args))
    (else (bad-arity 'draw-line-ex args))))

(define (draw-circle . args)
  (case (length args)
    ((4) (call-with-color %draw-circle-rgba (take args 3) (list-ref args 3)))
    ((7) (apply %draw-circle-rgba args))
    (else (bad-arity 'draw-circle args))))

(define (draw-circle-lines . args)
  (case (length args)
    ((4) (call-with-color %draw-circle-lines-rgba (take args 3) (list-ref args 3)))
    ((7) (apply %draw-circle-lines-rgba args))
    (else (bad-arity 'draw-circle-lines args))))

(define (draw-rectangle . args)
  (case (length args)
    ((5) (call-with-color %draw-rectangle-rgba (take args 4) (list-ref args 4)))
    ((8) (apply %draw-rectangle-rgba args))
    (else (bad-arity 'draw-rectangle args))))

(define (draw-rectangle-lines . args)
  (case (length args)
    ((5) (call-with-color %draw-rectangle-lines-rgba (take args 4) (list-ref args 4)))
    ((8) (apply %draw-rectangle-lines-rgba args))
    (else (bad-arity 'draw-rectangle-lines args))))

(define (draw-rectangle-gradient-v . args)
  (case (length args)
    ((6) (call-with-two-colors %draw-rectangle-gradient-v-rgba
                               (take args 4)
                               (list-ref args 4)
                               (list-ref args 5)))
    ((12) (apply %draw-rectangle-gradient-v-rgba args))
    (else (bad-arity 'draw-rectangle-gradient-v args))))

(define (draw-text . args)
  (case (length args)
    ((5) (call-with-color %draw-text-rgba (take args 4) (list-ref args 4)))
    ((8) (apply %draw-text-rgba args))
    (else (bad-arity 'draw-text args))))

(define (draw-text-ex . args)
  (case (length args)
    ((6) (call-with-color %draw-text-ex-rgba (take args 5) (list-ref args 5)))
    ((9) (apply %draw-text-ex-rgba args))
    (else (bad-arity 'draw-text-ex args))))

(define (draw-debug-text . args)
  (case (length args)
    ((5) (call-with-color %draw-debug-text-rgba (take args 4) (list-ref args 4)))
    ((8) (apply %draw-debug-text-rgba args))
    (else (bad-arity 'draw-debug-text args))))

(define load-font-ex
  (foreign-lambda bool "rl_load_font" c-string int))

(define load-debug-font-ex
  (foreign-lambda bool "rl_load_debug_font" c-string int))

(define measure-text
  (foreign-lambda int "rl_measure_text" c-string int))

(define key-pressed?
  (foreign-lambda bool "IsKeyPressed" int))

(define key-pressed-repeat?
  (foreign-lambda bool "IsKeyPressedRepeat" int))

(define key-down?
  (foreign-lambda bool "IsKeyDown" int))

(define key-released?
  (foreign-lambda bool "IsKeyReleased" int))

(define key-up?
  (foreign-lambda bool "IsKeyUp" int))

(define get-key-pressed
  (foreign-lambda int "GetKeyPressed"))

(define get-char-pressed
  (foreign-lambda int "GetCharPressed"))

(define get-key-name
  (foreign-lambda c-string "GetKeyName" int))

(define get-text-input
  (foreign-lambda c-string "rl_get_text_input"))

(define mouse-button-pressed?
  (foreign-lambda bool "IsMouseButtonPressed" int))

(define mouse-button-down?
  (foreign-lambda bool "IsMouseButtonDown" int))

(define mouse-button-released?
  (foreign-lambda bool "IsMouseButtonReleased" int))

(define mouse-button-up?
  (foreign-lambda bool "IsMouseButtonUp" int))

(define get-mouse-x
  (foreign-lambda int "GetMouseX"))

(define get-mouse-y
  (foreign-lambda int "GetMouseY"))

(define set-mouse-position
  (foreign-lambda void "SetMousePosition" int int))

(define get-mouse-wheel-move
  (foreign-lambda float "GetMouseWheelMove"))

(define set-mouse-cursor
  (foreign-lambda void "SetMouseCursor" int))

(define is-window-ready?
  (foreign-lambda bool "IsWindowReady"))

(define get-time
  (foreign-lambda double "GetTime"))

(define get-frame-time
  (foreign-lambda float "GetFrameTime"))

(define get-fps
  (foreign-lambda int "GetFPS"))

(define set-texture-filter
  (foreign-lambda void "rl_set_texture_filter" unsigned-int int))

(define set-text-line-spacing
  (foreign-lambda void "SetTextLineSpacing" int))

(define load-file-text
  (foreign-lambda c-string "LoadFileText" c-string))

(define unload-file-text
  (foreign-lambda void "UnloadFileText" c-string))

(define save-file-text
  (foreign-lambda bool "SaveFileText" c-string c-string))

(define set-clipboard-text
  (foreign-lambda void "SetClipboardText" c-string))

(define get-clipboard-text
  (foreign-lambda c-string "GetClipboardText"))

(define set-window-title
  (foreign-lambda void "SetWindowTitle" c-string))

(define set-window-size
  (foreign-lambda void "SetWindowSize" int int))

(define set-window-position
  (foreign-lambda void "SetWindowPosition" int int))

(define is-window-resized?
  (foreign-lambda bool "IsWindowResized"))

(define is-window-focused?
  (foreign-lambda bool "IsWindowFocused"))

(define is-window-fullscreen?
  (foreign-lambda bool "IsWindowFullscreen"))

(define toggle-fullscreen
  (foreign-lambda void "ToggleFullscreen"))

(define maximize-window
  (foreign-lambda void "MaximizeWindow"))

(define minimize-window
  (foreign-lambda void "MinimizeWindow"))

(define restore-window
  (foreign-lambda void "RestoreWindow"))

(define get-window-scale-dpi
  (foreign-lambda float "rl_get_window_scale_dpi_x"))

(define set-config-flags
  (foreign-lambda void "SetConfigFlags" unsigned-int))

(define show-cursor
  (foreign-lambda void "ShowCursor"))

(define hide-cursor
  (foreign-lambda void "HideCursor"))

(define cursor-hidden?
  (foreign-lambda bool "IsCursorHidden"))
)
