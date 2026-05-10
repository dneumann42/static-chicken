;; raylib.scm — minimal CHICKEN 5 FFI bindings for raylib 6.0.
;; Color is passed as four ints (r g b a) and rebuilt inside small C shims to
;; dodge struct-by-value FFI quirks.
;;
;; Compiled as a separate unit and linked into the final binary.

(declare (unit raylib))

(import (chicken foreign))

(foreign-declare "#include \"raylib.h\"")
(foreign-declare "#include <string.h>")

(foreign-declare #<<EOF
static Font rl_loaded_font = { 0 };

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
static void rl_draw_text(const char *txt, int x, int y, int sz,
                         int r, int g, int b, int a) {
    Color c; c.r=(unsigned char)r; c.g=(unsigned char)g;
             c.b=(unsigned char)b; c.a=(unsigned char)a;
    if (rl_loaded_font.texture.id != 0) {
        Vector2 pos = { (float)x, (float)y };
        DrawTextEx(rl_loaded_font, txt, pos, (float)sz, 1.0f, c);
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
        const char *utf8 = CodepointToUTF8(codepoint, &bytes);
        if (utf8 != NULL && bytes > 0 && len + bytes < (int)sizeof(buf)) {
            memcpy(buf + len, utf8, (size_t)bytes);
            len += bytes;
            buf[len] = '\0';
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

(define clear-background
  (foreign-lambda void "rl_clear_background" int int int int))

(define draw-rectangle
  (foreign-lambda void "rl_draw_rectangle"
                  int int int int int int int int))

(define draw-text
  (foreign-lambda void "rl_draw_text"
                  c-string int int int int int int int))

(define load-font-ex
  (foreign-lambda bool "rl_load_font" c-string int))

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

(define is-window-resized?
  (foreign-lambda bool "IsWindowResized"))

(define get-window-scale-dpi
  (foreign-lambda float "rl_get_window_scale_dpi_x"))

(define set-config-flags
  (foreign-lambda void "SetConfigFlags" unsigned-int))
