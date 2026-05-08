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
  main.scm
  src/
  plugins/
  vendor/static-chicken/
```

Add it with:

```sh
git submodule add git@github.com:dneumann42/static-chicken.git vendor/static-chicken
```

`main.scm`, `src/**/*.scm`, and `plugins/**/*.scm` are loaded by the host and
watched for changes. `runtime.scm`, `raylib.scm`, the Raylib patch, and the
build/bootstrap scripts stay in the submodule.

## Automated Setup

Put this script in the project directory you want to turn into a
`static-chicken` app. It adds `static-chicken` as a submodule, writes a starter
`main.scm`, bootstraps the SDK, and builds the first Wayland binary. The binary
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

mkdir -p src plugins vendor
touch src/.gitkeep plugins/.gitkeep

if [ ! -d vendor/static-chicken ]; then
  git submodule add "$SDK_URL" vendor/static-chicken
fi

if [ ! -f main.scm ]; then
  cat > main.scm <<'SCM'
(once! 'window
       (lambda ()
         (init-window 800 600 "static-chicken app")
         (set-target-fps 60)))

(set! *on-draw*
      (lambda ()
        (draw-rectangle 200 150 400 300 240 80 60 255)
        (draw-text "edit main.scm" 300 100 28 240 240 240 255)
        (draw-text "REPL: rlwrap nc localhost 1234" 260 470 18 180 180 200 255)))
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
vendor/static-chicken/build.sh wayland
```

or:

```sh
vendor/static-chicken/build.sh x11
```

The output binary is written to:

```text
build/static-chicken/<target>/myapp
```

Set `STATIC_CHICKEN_APP_NAME` to change the executable name:

```sh
STATIC_CHICKEN_APP_NAME=my-game vendor/static-chicken/build.sh wayland
```

Run the binary from the app root so default runtime paths resolve to the app:

```sh
build/static-chicken/wayland/myapp
```

If you run it from another directory, set `STATIC_CHICKEN_APP_ROOT`:

```sh
STATIC_CHICKEN_APP_ROOT=/path/to/my-app build/static-chicken/wayland/myapp
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
| `STATIC_CHICKEN_ENTRY` | `main.scm` | Entry file loaded before watched directories |
| `STATIC_CHICKEN_WATCH_DIRS` | `src:plugins` | Colon-separated directories to hot-load/watch |
| `REPL_PORT` | `1234` | TCP REPL port on `127.0.0.1` |

`once!` is available for CL-style one-time initialization across reloads:

```scheme
(once! 'window
       (lambda ()
         (init-window 800 600 "my app")
         (set-target-fps 60)))
```

Set `*on-draw*` to the thunk the host should call every draw frame.

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

This repository includes `examples/basic/main.scm`. From the SDK root:

```sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./configure.sh
STATIC_CHICKEN_APP_ROOT=examples/basic ./build.sh wayland
STATIC_CHICKEN_APP_ROOT=examples/basic examples/basic/build/static-chicken/wayland/myapp
```

While the app runs, connect to the live image:

```sh
rlwrap nc 127.0.0.1 1234
```
