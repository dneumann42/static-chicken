#!/bin/bash
# Build a CHICKEN binary that uses raylib 6.0's software renderer.
#
# Targets:
#   wayland  (default)  Wayland backend, partial-static binary.
#   x11                 X11 backend, partial-static binary.
#
# Usage:  ./build.sh [wayland|x11]
#
# Stages: (1) musl-build CHICKEN  (2) musl-build raylib for the target
#         (3) compile main.scm and link.

set -euo pipefail

TARGET="${1:-wayland}"
case "$TARGET" in wayland|x11) ;; *)
  echo "Unknown target: $TARGET (expected: wayland | x11)"; exit 1;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
CC_MUSL="${CC_MUSL:-musl-gcc}"
JOBS="${JOBS:-$(nproc)}"

CHICKEN_SRC="$ROOT/chicken-5.4.0"
CHICKEN_PREFIX="$ROOT/chicken-musl"
RAYLIB_SRC="$ROOT/vendor/raylib/src"
BUILD="$ROOT/build/$TARGET"
mkdir -p "$BUILD"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

# 0. Sanity
command -v "$CC_MUSL" >/dev/null \
  || { echo "ERROR: $CC_MUSL not found. Run ./configure.sh first."; exit 1; }
[ -d "$CHICKEN_SRC" ] \
  || { echo "ERROR: $CHICKEN_SRC missing. Run ./configure.sh first."; exit 1; }
[ -d "$RAYLIB_SRC" ] \
  || { echo "ERROR: $RAYLIB_SRC missing. Run ./configure.sh first."; exit 1; }

# Build vendored Wayland-stack deps if missing (only needed for the wayland target).
DEPS_PREFIX="$ROOT/vendor/deps/prefix"
if [ "$TARGET" = wayland ] && [ ! -f "$DEPS_PREFIX/lib64/libwayland-client.a" ]; then
  log "Wayland deps missing — running ./build-deps.sh"
  "$ROOT/build-deps.sh"
fi

# 1. CHICKEN musl rebuild (one-time, shared between targets)
if [ ! -x "$CHICKEN_PREFIX/bin/csc" ]; then
  log "Building CHICKEN 5.4.0 with musl into $CHICKEN_PREFIX"
  cd "$CHICKEN_SRC"
  make confclean >/dev/null 2>&1 || true
  make spotless  >/dev/null 2>&1 || true
  make -j"$JOBS" PLATFORM=linux PREFIX="$CHICKEN_PREFIX" C_COMPILER="$CC_MUSL"
  make           PLATFORM=linux PREFIX="$CHICKEN_PREFIX" C_COMPILER="$CC_MUSL" install
fi

# 1b. CHICKEN eggs needed by runtime.scm (TCP REPL + hash tables + threads).
# Install into chicken-musl's repo on first build. Requires network access.
for egg in srfi-1 srfi-18 srfi-69; do
  if [ ! -f "$CHICKEN_PREFIX/lib/chicken/11/${egg}.import.so" ]; then
    log "Installing CHICKEN egg: $egg"
    (cd /tmp && "$CHICKEN_PREFIX/bin/chicken-install" "$egg")
  fi
done

# 2. raylib 6.0 static lib (per-target — switching backends needs a clean rebuild)
RAYLIB_STAMP="$RAYLIB_SRC/.built-$TARGET"
if [ ! -f "$RAYLIB_STAMP" ]; then
  log "Building raylib 6.0 static lib (target: $TARGET, software renderer, musl)"
  cd "$RAYLIB_SRC"
  make clean >/dev/null 2>&1 || true
  rm -f .built-*

  case "$TARGET" in
    wayland)
      # Generate wayland protocol code
      for proto in pointer-constraints-unstable-v1 pointer-warp-v1 \
                   relative-pointer-unstable-v1 xdg-decoration-unstable-v1 \
                   xdg-output-unstable-v1 xdg-shell xdg-toplevel-icon-v1; do
        wayland-scanner private-code  external/RGFW/deps/wayland/$proto.xml \
                        $proto-client-protocol-code.c
        wayland-scanner client-header external/RGFW/deps/wayland/$proto.xml \
                        $proto-client-protocol.h
      done

      make -j"$JOBS" \
           PLATFORM=PLATFORM_DESKTOP_RGFW \
           GRAPHICS=GRAPHICS_API_OPENGL_SOFTWARE \
           RAYLIB_LIBTYPE=STATIC \
           RAYLIB_MODULE_AUDIO=FALSE \
           RAYLIB_MODULE_MODELS=FALSE \
           RGFW_LINUX_ENABLE_X11=FALSE \
           RGFW_LINUX_ENABLE_WAYLAND=TRUE \
           CC="$CC_MUSL" \
           CUSTOM_CFLAGS="-DRGFW_WAYLAND -DRGFW_NO_X11 -idirafter /usr/include"
      ;;

    x11)
      make -j"$JOBS" \
           PLATFORM=PLATFORM_DESKTOP_RGFW \
           GRAPHICS=GRAPHICS_API_OPENGL_SOFTWARE \
           RAYLIB_LIBTYPE=STATIC \
           RAYLIB_MODULE_AUDIO=FALSE \
           RAYLIB_MODULE_MODELS=FALSE \
           CC="$CC_MUSL" \
           CUSTOM_CFLAGS="-idirafter /usr/include"
      ;;
  esac
  touch "$RAYLIB_STAMP"
fi

# 3. Compile + link the runtime/host (main.scm + src/ + plugins/ load at runtime)
log "Compiling runtime.scm + raylib.scm and linking ($TARGET)"
cd "$ROOT"
CSC="$CHICKEN_PREFIX/bin/csc"

case "$TARGET" in
  wayland)
    LINK_LIBS=(-L "-static"
               -L "-L$DEPS_PREFIX/lib64"
               -L "-L$DEPS_PREFIX/lib"
               -L "-lwayland-client" -L "-lwayland-cursor"
               -L "-lwayland-egl"
               -L "-lxkbcommon" -L "-lffi"
               -L "-lm" -L "-lpthread" -L "-ldl" -L "-lrt")
    ;;
  x11)
    LINK_LIBS=(-L "-lX11" -L "-lXrandr" -L "-lXinerama"
               -L "-lXi"  -L "-lXcursor"
               -L "-lGL"
               -L "-lm" -L "-lpthread" -L "-ldl" -L "-lrt")
    ;;
esac

# Compile raylib bindings as a separate unit.
# -d1 (not -d0) is required so eval/REPL can resolve module exports at runtime.
"$CSC" -O3 -d1 -static \
       -cc "$CC_MUSL" \
       -C "-I$RAYLIB_SRC" \
       -c "$ROOT/raylib.scm" \
       -o "$BUILD/raylib.o"

# csc's find-object-file searches cwd for raylib.o (matching the unit referenced
# via runtime.scm's (declare (uses raylib))). Run the link step from $BUILD.
cd "$BUILD"
"$CSC" -O3 -d1 -static \
       -cc "$CC_MUSL" \
       -C "-I$RAYLIB_SRC" \
       -L "$RAYLIB_SRC/libraylib.a" \
       "${LINK_LIBS[@]}" \
       "$ROOT/runtime.scm" \
       -o myapp
cd "$ROOT"

log "Built: $BUILD/myapp"
file "$BUILD/myapp"
echo
echo "Dynamic deps:"
ldd "$BUILD/myapp" 2>&1 | sed 's/^/  /'
