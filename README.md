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

Set `*on-frame*` to the thunk the host should call every frame.

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
