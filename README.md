# static-chicken

`static-chicken` is a small SDK for building hot-reloaded CHICKEN Scheme apps
on top of a mostly static Raylib host. It is intentionally not packaged as a
normal CHICKEN egg: the reusable boundary is the compiled host/runtime plus its
vendored native build, while each app owns the Scheme files that are loaded at
runtime.

## Project Layout

Use this repository as a submodule in each app:

```text
my-app/
  src/
    main.scm
  vendor/static-chicken/
```

Add it with:

```sh
git submodule add git@github.com:dneumann42/static-chicken.git vendor/static-chicken
```

Every `src/**/*.scm` file is loaded by the host as a module named from its path:
`src/main.scm` becomes `main`, and `src/gameplay/doors.scm` becomes
`gameplay-doors`. Source files should contain normal top-level forms without a
manual `(module ...)` wrapper. `runtime.scm`, `raylib.scm`, the Raylib patch,
and the build/bootstrap scripts stay in the submodule.

## Automated Setup

Put this script in the project directory you want to turn into a
`static-chicken` app. It adds `static-chicken` as a submodule, writes a starter
`src/main.scm`, bootstraps the SDK, and builds the first Wayland binary. The binary
name is derived from the project directory name.

```sh
#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_NAME="${STATIC_CHICKEN_APP_NAME:-$(basename "$SCRIPT_DIR")}"
SDK_URL="${STATIC_CHICKEN_SDK_URL:-git@github.com:dneumann42/static-chicken.git}"
TARGET="${STATIC_CHICKEN_TARGET:-wayland}"

cd "$SCRIPT_DIR"

if [ ! -d .git ]; then
  git init
fi

mkdir -p src vendor

if [ ! -d vendor/static-chicken ]; then
  git submodule add "$SDK_URL" vendor/static-chicken
fi

if [ ! -f src/main.scm ]; then
  cat > src/main.scm <<'SCM'
(import scheme (chicken eval) raylib)

(define (runtime-call name . args)
  (apply (eval name) args))

(define (init)
  (init-window 800 600 "static-chicken app")
  (set-target-fps 60))

(runtime-call 'once! 'window init)
(runtime-call
 'set-on-draw!
 (lambda ()
   (draw-rectangle 200 150 400 300 color-tomato)
   (draw-rectangle-lines 200 150 400 300 'raywhite)
   (draw-text "edit src/main.scm" 300 100 28 'raywhite)
   (draw-text "REPL: rlwrap nc localhost 1234" 260 470 18 'lightgray)))
SCM
fi

vendor/static-chicken/configure.sh
STATIC_CHICKEN_APP_NAME="$APP_NAME" vendor/static-chicken/build.sh "$TARGET"

printf '\nBuilt: %s\n' "build/static-chicken/$TARGET/$APP_NAME"
printf 'Run from %s with:\n  %s\n' "$PWD" "build/static-chicken/$TARGET/$APP_NAME"
```

Save it as `bootstrap.sh` in a project directory, make it executable, and run:

```sh
mkdir -p ~/Projects/s-expr-edit
cd ~/Projects/s-expr-edit
./bootstrap.sh
```

## Bootstrap

From the consumer project root:

```sh
vendor/static-chicken/configure.sh
```

That installs system packages when possible, fetches pinned CHICKEN/Raylib
sources, applies local patches, and prepares vendored Wayland dependencies.

## Build

From the consumer project root:

```sh
vendor/static-chicken/build.sh wayland software
```

or:

```sh
vendor/static-chicken/build.sh wayland hardware
vendor/static-chicken/build.sh x11 software
vendor/static-chicken/build.sh x11 hardware
```

The output binary is written to:

```text
build/static-chicken/<target>/<renderer>/myapp
```

The default renderer is `software`. Software mode uses the musl toolchain and
can produce a fully static binary. Hardware mode uses OpenGL 3.3 with the native
system toolchain so it can load the system GL/EGL driver libraries required by
Linux hardware rendering.

Set `STATIC_CHICKEN_APP_NAME` to change the executable name:

```sh
STATIC_CHICKEN_APP_NAME=my-game vendor/static-chicken/build.sh wayland hardware
```

Run the binary from the app root so default runtime paths resolve to the app:

```sh
build/static-chicken/wayland/hardware/myapp
```

If you run it from another directory, set `STATIC_CHICKEN_APP_ROOT`:

```sh
STATIC_CHICKEN_APP_ROOT=/path/to/my-app build/static-chicken/wayland/hardware/myapp
```

If CHICKEN fails while building `user-pass.scm` with an unresolved
`make-parameter`, the build picked up an incompatible system `chicken` after the
release C sources were removed. Update the `static-chicken` submodule and rerun
`vendor/static-chicken/build.sh`; the script restores the release sources from
`chicken-5.4.0.tar.gz` before building.

## Runtime Configuration

The host reads these environment variables at startup:

| Variable | Default | Purpose |
| --- | --- | --- |
| `STATIC_CHICKEN_APP_ROOT` | current directory | Root directory for app files |
| `STATIC_CHICKEN_ENTRY` | `src/main.scm` | Legacy entry setting; source loading now uses watched source roots |
| `STATIC_CHICKEN_HOTLOAD_MODULE` | `apothecary` | Module searched for optional `before-hotload!` / `after-hotload!` hooks |
| `STATIC_CHICKEN_RENDERER` | `software` | Build-time renderer selection for `build.sh`: `software` or `hardware` |
| `STATIC_CHICKEN_WATCH_DIRS` | `src` | Colon-separated source roots to auto-module-load/watch |
| `STATIC_CHICKEN_WATCH` | unset | Set to `1` to poll watched files every frame and reload on change. When unset, sources are loaded once at startup and reloads must be triggered manually (REPL `(check-watches!)` or the Emacs hook). |
| `STATIC_CHICKEN_DEBUG_FONT` | `vendor/static-chicken/assets/fonts/SpaceMono-Regular.ttf` | TTF used by the runtime error overlay |
| `STATIC_CHICKEN_LOG_LINES` | `200` | Maximum stdout lines kept in the in-game log panel |
| `REPL_PORT` | `1234` | TCP REPL port on `127.0.0.1` |

`once!` is available for CL-style one-time initialization across reloads:

```scheme
(once! 'window
       (lambda ()
         (init-window 800 600 "my app")
         (set-target-fps 60)))
```

Set `*on-draw*` to the thunk the host should call every draw frame.

Runtime load, update, and draw errors are caught by the host. The on-screen
overlay shows the formatted error, source line when CHICKEN provides one,
arguments, and a compact hint. Press `F8` while an error is visible to expand or
collapse the stacktrace. Press `F11`, or click anywhere in the error panel, to
open the reported source line in a running Emacs server via `emacsclient -n`.

The debug overlay uses the bundled Space Mono Regular font from
`assets/fonts/SpaceMono-Regular.ttf`; set `STATIC_CHICKEN_DEBUG_FONT` to use a
different `.ttf`.

Stdout is tee'd to the terminal and to an in-game log panel. Press `F10` to show
or hide the log panel; use the mouse wheel or `PageUp` / `PageDown` to scroll.
The panel keeps the last `STATIC_CHICKEN_LOG_LINES` lines.

Press `F12` to show or hide the runtime debug overlay. It currently displays a
rolling average FPS calculated from the last 60 frame durations.

Press `F9` to show the watch panel. Enter a Scheme expression to pin it on
screen; each pinned expression is compiled into a thunk, refreshed periodically,
and pretty-printed in a sticker. Records without custom printers are shown as
their raw record vector, including the type and slots. For named fields, add a
CHICKEN record printer:

```scheme
(set-record-printer! point
  (lambda (p out)
    (fprintf out "#,(point x: ~S y: ~S)" (point-x p) (point-y p))))
```

Right-click a sticker to remove it.

Space Mono is distributed under the SIL Open Font License 1.1. The font and its
license are shipped together in `assets/fonts/`, as required by the OFL when
redistributing the font with software.

Colors are Scheme records. Drawing helpers accept a color object, a palette
symbol, an RGB/RGBA list, or the older raw `r g b a` arguments:

```scheme
(define accent (make-color 240 80 60))

(clear-background color-black)
(draw-rectangle 200 150 400 300 accent)
(draw-rectangle-lines 200 150 400 300 'raywhite)
(draw-text "hello" 260 100 28 'raywhite)

;; Still accepted for compatibility:
(draw-text "old style" 260 140 18 180 180 200 255)
```

Common Raylib palette constants are available as `color-red`, `color-blue`,
`color-raywhite`, etc. The same names are also available as symbols such as
`'red`, `'blue`, and `'raywhite`.

Additional drawing helpers include:

```scheme
(draw-pixel x y color)
(draw-line x1 y1 x2 y2 color)
(draw-line-ex x1 y1 x2 y2 thickness color)
(draw-circle x y radius color)
(draw-circle-lines x y radius color)
(draw-rectangle-gradient-v x y w h top-color bottom-color)
(draw-text-ex text x y size spacing color)
```

Input helpers mirror Raylib's polling API:

```scheme
(key-pressed? key-enter)
(key-down? key-left-shift)
(mouse-button-pressed? mouse-button-left)
(get-mouse-x)
(get-mouse-y)
```

For text fields, call `get-text-input` once per frame to drain queued UTF-8
text input:

```scheme
(let ((typed (get-text-input)))
  (unless (string=? typed "")
    ;; append typed to your editor/input buffer
    typed))
```

## Emacs Integration

`editor/static-chicken.el` ships a minor mode that binds `C-c C-c` to save
every modified `.scm` buffer and send `(check-watches!)` over the TCP REPL so
the running app reloads only the files that changed. It works whether or not
the app was started with `STATIC_CHICKEN_WATCH=1`.

```elisp
(add-to-list 'load-path
             (expand-file-name "vendor/static-chicken/editor"
                               "/path/to/my-app"))
(require 'static-chicken)
(add-hook 'scheme-mode-hook #'static-chicken-mode)
```

The plain comint REPL persists command history in `.static-chicken-repl-history`
at the project root. Use C-r in the REPL buffer to search that history.

The REPL can also ask Emacs for minibuffer-completion choices and register TAB
completion candidates:

```scheme
(repl-completions! 'npc-types '("Cuthbert" "Humbert"))

(let ((npc-type (repl-choose "Spawn NPC: "
                             '("Cuthbert" "Humbert")
                             '((default . "Cuthbert")))))
  (spawn-npc *entity-manager* '(100 100) npc-type))
```

Use `repl-input` for free-form minibuffer input with defaults:

```scheme
(repl-input "Spawn X: " '((default . "100")))
```

Customize `static-chicken-repl-host` / `static-chicken-repl-port` if the app
listens on a non-default address.

## Updating Apps

Each app pins a specific SDK commit through its submodule. To pick up runtime or
build changes:

```sh
cd vendor/static-chicken
git fetch
git checkout origin/master
cd ../..
git add vendor/static-chicken
git commit -m "Update static-chicken SDK"
```

This updates the shared runtime/build system without copying SDK files into the
app repository.

## Example

This repository includes `examples/basic/src/main.scm`. From the SDK root:

```sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./configure.sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./build.sh wayland
STATIC_CHICKEN_APP_ROOT=examples/basic examples/basic/build/static-chicken/wayland/myapp
```

While the app runs, connect to the live image:

```sh
rlwrap nc 127.0.0.1 1234
```
