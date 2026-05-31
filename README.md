# static-chicken

`static-chicken` is a small SDK for building hot-reloaded CHICKEN Scheme apps
on top of a mostly static Raylib host. Vendor it as a submodule inside each app
and keep your app code in `src/`.

## Use It In An App

Add the SDK as a submodule:

```sh
git submodule add git@github.com:dneumann42/static-chicken.git vendor/static-chicken
```

Bootstrap the host/runtime dependencies:

```sh
vendor/static-chicken/bin/configure.sh
```

Build the app:

```sh
STATIC_CHICKEN_APP_NAME=myapp vendor/static-chicken/bin/build.sh wayland hardware
```

The binary lands at:

```text
build/static-chicken/<target>/<renderer>/<app-name>
```

## How Source Loading Works

The runtime scans the directories listed in `STATIC_CHICKEN_WATCH_DIRS`
(default: `src`) and loads every `.scm` file it finds there.

Each file becomes a module whose name comes from its relative path:

- `src/main.scm` -> `main`
- `src/gameplay/doors.scm` -> `gameplay-doors`
- `src/entities/entity-system.scm` -> `entities-entity-system`

Because the host wraps each file as a module automatically, app sources should
be plain top-level Scheme forms. Do not add a manual `(module ...)` wrapper in
your app files.

The loader reads top-level `import` forms, sorts files so dependencies load
before dependents, and then loads the modules in that order. If there is an
import cycle, it warns and falls back to a stable filename order for the cycle.

If you want another watched source root, add it to `STATIC_CHICKEN_WATCH_DIRS`
with a colon-separated list, for example:

```sh
STATIC_CHICKEN_WATCH_DIRS=src:plugins
```

## App Startup Pattern

Use `src/main.scm` as the startup file for new apps. It is the natural place to
do one-time initialization and connect the host callbacks.

Host globals such as `once!`, `set-on-draw!`, and `set-on-update!` live in the
runtime image. A simple way to call them from app code is to route through
`eval`:

```scheme
(import scheme (chicken eval) raylib)

(define (runtime-call name . args)
  (apply (eval name) args))

(define (init)
  (init-window 800 600 "my app")
  (set-target-fps 60))

(runtime-call 'once! 'window init)
(runtime-call
 'set-on-draw!
 (lambda ()
   (draw-rectangle 200 150 400 300 color-tomato)
   (draw-text "edit src/main.scm" 220 100 28 'raywhite)))
```

Keep game logic in other files under `src/` and import them by their path-based
module names. Example:

```scheme
(import scheme gameplay-doors entities-entity-system)
```

## Build And Run

From the consumer project root:

```sh
vendor/static-chicken/bin/build.sh wayland software
vendor/static-chicken/bin/build.sh wayland hardware
vendor/static-chicken/bin/build.sh x11 software
vendor/static-chicken/bin/build.sh x11 hardware
```

Set `STATIC_CHICKEN_APP_NAME` to change the output binary name, and
`STATIC_CHICKEN_APP_ROOT` if you build from outside the app root.

`software` uses the musl toolchain and can produce a fully static binary.
`hardware` uses the native toolchain and links against the system GL/EGL stack.

## Reloading

`./run.sh --watch` turns on per-frame polling for file changes. Without it, the
app loads once at startup and stays fixed until you call `(check-watches!)`
over the TCP REPL.

The app opens a REPL on `127.0.0.1:$REPL_PORT` (default `1234`). Connect with:

```sh
rlwrap nc 127.0.0.1 1234
```

The Emacs helper in `tools/emacs/static-chicken.el` binds `C-c C-c` to save
modified Scheme buffers and trigger `(check-watches!)` on the running app.

## Example

`examples/basic/src/main.scm` shows the minimal startup pattern for a new app.
From the SDK root:

```sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./bin/configure.sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./bin/build.sh wayland
STATIC_CHICKEN_APP_ROOT=examples/basic examples/basic/build/static-chicken/wayland/myapp
```

## Updating The SDK

Update the submodule in the consumer app, then commit the new pointer:

```sh
cd vendor/static-chicken
git fetch
git checkout origin/master
cd ../..
git add vendor/static-chicken
git commit -m "Update static-chicken SDK"
```
