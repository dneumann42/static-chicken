#!/bin/bash
# Build a CHICKEN binary that uses raylib 6.0.
#
# Targets:
#   wayland  (default)  Wayland backend, partial-static binary.
#   x11                 X11 backend, partial-static binary.
#
# Renderers:
#   software (default)  CPU software renderer.
#   hardware            OpenGL 3.3 hardware renderer.
#
# Usage:  ./build.sh [wayland|x11] [software|hardware]
#
# When used as a submodule, run this script from the consumer project root:
#   vendor/static-chicken/build.sh wayland hardware
#
# Environment:
#   STATIC_CHICKEN_APP_ROOT   app source root; defaults to current directory
#   STATIC_CHICKEN_APP_NAME   output binary name; defaults to myapp
#   STATIC_CHICKEN_RENDERER   software|hardware; defaults to software
#
# Stages: (1) build CHICKEN  (2) build raylib for the target/renderer
#         (3) compile the SDK runtime host and link.

set -euo pipefail

TARGET="${STATIC_CHICKEN_TARGET:-wayland}"
RENDERER="${STATIC_CHICKEN_RENDERER:-software}"

for arg in "$@"; do
  case "$arg" in
    wayland|x11)
      TARGET="$arg"
      ;;
    software|hardware)
      RENDERER="$arg"
      ;;
    *)
      echo "Unknown argument: $arg (expected: wayland | x11 | software | hardware)"; exit 1;;
  esac
done

case "$TARGET" in wayland|x11) ;; *)
  echo "Unknown target: $TARGET (expected: wayland | x11)"; exit 1;;
esac
case "$RENDERER" in software|hardware) ;; *)
  echo "Unknown renderer: $RENDERER (expected: software | hardware)"; exit 1;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="${STATIC_CHICKEN_APP_ROOT:-$PWD}"
APP_ROOT="$(cd "$APP_ROOT" && pwd)"
APP_NAME="${STATIC_CHICKEN_APP_NAME:-myapp}"
CC_MUSL="${CC_MUSL:-musl-gcc}"
CC_NATIVE="${CC_NATIVE:-gcc}"
JOBS="${JOBS:-$(nproc)}"

CHICKEN_SRC="$ROOT/chicken-5.4.0"
CHICKEN_TARBALL="$ROOT/chicken-5.4.0.tar.gz"
RAYLIB_SRC="$ROOT/vendor/raylib/src"
BUILD="$APP_ROOT/build/static-chicken/$TARGET/$RENDERER"
mkdir -p "$BUILD"

case "$RENDERER" in
  software)
    CC_BUILD="$CC_MUSL"
    CHICKEN_PREFIX="$ROOT/chicken-musl"
    ;;
  hardware)
    CC_BUILD="$CC_NATIVE"
    CHICKEN_PREFIX="$ROOT/chicken-native"
    ;;
esac

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

arch_needs_atomic_libdir() {
  [ -f /etc/os-release ] || return 1
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*) [ -e /usr/lib/libatomic_asneeded.a ] ;;
    *) return 1 ;;
  esac
}

if arch_needs_atomic_libdir; then
  export LIBRARY_PATH="/usr/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LDFLAGS="${LDFLAGS:-} -L/usr/lib"
fi

# 0. Sanity
command -v "$CC_BUILD" >/dev/null \
  || { echo "ERROR: $CC_BUILD not found. Run ./configure.sh first."; exit 1; }
[ -d "$CHICKEN_SRC" ] \
  || { echo "ERROR: $CHICKEN_SRC missing. Run ./configure.sh first."; exit 1; }
[ -d "$RAYLIB_SRC" ] \
  || { echo "ERROR: $RAYLIB_SRC missing. Run ./configure.sh first."; exit 1; }

# Build vendored Wayland-stack deps if missing (only needed for software Wayland).
DEPS_PREFIX="$ROOT/vendor/deps/prefix"
if [ "$TARGET" = wayland ] && [ "$RENDERER" = software ] &&
   [ ! -f "$DEPS_PREFIX/lib64/libwayland-client.a" ] &&
   [ ! -f "$DEPS_PREFIX/lib/libwayland-client.a" ]; then
  log "Wayland deps missing — running ./build-deps.sh"
  "$ROOT/build-deps.sh"
fi

# 1. CHICKEN rebuild (one-time per renderer toolchain)
if [ ! -x "$CHICKEN_PREFIX/bin/csc" ]; then
  log "Building CHICKEN 5.4.0 with $CC_BUILD into $CHICKEN_PREFIX"

  # CHICKEN release tarballs include pregenerated C sources and can be built
  # without a compatible host chicken. Do not run spotless here: it deletes
  # those generated files and may make make pick up an incompatible system
  # chicken, such as CHICKEN 6 while building CHICKEN 5.4.0.
  if [ ! -f "$CHICKEN_SRC/buildid" ] || [ ! -f "$CHICKEN_SRC/library.c" ]; then
    [ -f "$CHICKEN_TARBALL" ] \
      || { echo "ERROR: $CHICKEN_TARBALL missing. Run ./configure.sh first."; exit 1; }
    log "Restoring CHICKEN release sources from tarball"
    rm -rf "$CHICKEN_SRC"
    tar -xzf "$CHICKEN_TARBALL" -C "$ROOT"
  fi

  cd "$CHICKEN_SRC"
  make clean >/dev/null 2>&1 || true
  make PLATFORM=linux PREFIX="$CHICKEN_PREFIX" C_COMPILER="$CC_BUILD"
  make           PLATFORM=linux PREFIX="$CHICKEN_PREFIX" C_COMPILER="$CC_BUILD" install
fi

clean_cached_egg_build_outputs() {
  local egg="$1"
  local cache="${CHICKEN_INSTALL_CACHE:-$HOME/.cache/chicken-install}/$egg"
  [ -d "$cache" ] || return 0
  find "$cache" -type f \
    \( -name '*.so' -o -name '*.o' -o -name '*.link' -o -name 'build-*' \) \
    -delete
}

for egg in srfi-1 srfi-18 srfi-69 matchable miscmacros record-variants coops; do
  clean_cached_egg_build_outputs "$egg"
done

egg_needs_install() {
  local egg="$1"
  local import_so="$CHICKEN_PREFIX/lib/chicken/11/${egg}.import.so"
  [ -f "$import_so" ] || return 0
  readelf -d "$import_so" 2>/dev/null | grep -q "$CHICKEN_PREFIX" || return 0
  return 1
}

# 1b. CHICKEN eggs needed by runtime.scm (TCP REPL + hash tables + threads).
# Install into the selected CHICKEN repo on first build.
for egg in srfi-1 srfi-18 srfi-69 matchable miscmacros record-variants coops; do
  if egg_needs_install "$egg"; then
    log "Installing CHICKEN egg: $egg"
    (cd /tmp && "$CHICKEN_PREFIX/bin/chicken-install" -cached -force -keep "$egg")
  fi
done

copy_import_library() {
  local egg="$1"
  local module="$2"
  local src="${CHICKEN_INSTALL_CACHE:-$HOME/.cache/chicken-install}/$egg/$module.import.scm"
  if [ -f "$src" ]; then
    install -m 0644 "$src" "$ROOT/$module.import.scm"
  elif [ ! -f "$ROOT/$module.import.scm" ]; then
    echo "ERROR: missing source import library for $module: $src" >&2
    echo "       Reinstall with: $CHICKEN_PREFIX/bin/chicken-install -cached -force -keep $egg" >&2
    exit 1
  fi
}

copy_import_library matchable matchable
copy_import_library miscmacros miscmacros
copy_import_library record-variants record-variants
copy_import_library coops coops
copy_import_library coops coops-primitive-objects

# 2. raylib 6.0 static lib (per-target/renderer — switching needs a clean rebuild)
RAYLIB_STAMP="$RAYLIB_SRC/.built-$TARGET-$RENDERER"
case "$RENDERER" in
  software) RAYLIB_GRAPHICS=GRAPHICS_API_OPENGL_SOFTWARE ;;
  hardware) RAYLIB_GRAPHICS=GRAPHICS_API_OPENGL_33 ;;
esac
if [ ! -f "$RAYLIB_STAMP" ]; then
  log "Building raylib 6.0 static lib (target: $TARGET, renderer: $RENDERER, compiler: $CC_BUILD)"
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
           GRAPHICS="$RAYLIB_GRAPHICS" \
           RAYLIB_LIBTYPE=STATIC \
           RAYLIB_MODULE_AUDIO=FALSE \
           RAYLIB_MODULE_MODELS=FALSE \
           RGFW_LINUX_ENABLE_X11=FALSE \
           RGFW_LINUX_ENABLE_WAYLAND=TRUE \
           CC="$CC_BUILD" \
           CUSTOM_CFLAGS="-DRGFW_WAYLAND -DRGFW_NO_X11 -idirafter /usr/include"
      ;;

    x11)
      make -j"$JOBS" \
           PLATFORM=PLATFORM_DESKTOP_RGFW \
           GRAPHICS="$RAYLIB_GRAPHICS" \
           RAYLIB_LIBTYPE=STATIC \
           RAYLIB_MODULE_AUDIO=FALSE \
           RAYLIB_MODULE_MODELS=FALSE \
           CC="$CC_BUILD" \
           CUSTOM_CFLAGS="-idirafter /usr/include"
      ;;
  esac
  touch "$RAYLIB_STAMP"
fi

# 3. Compile + link the runtime/host (main.scm + src/ + plugins/ load at runtime)
log "Compiling runtime.scm + raylib.scm and linking ($TARGET/$RENDERER)"
cd "$ROOT"
CSC="$CHICKEN_PREFIX/bin/csc"

case "$TARGET" in
  wayland)
    LINK_LIBS=(-L "-lwayland-client" -L "-lwayland-cursor"
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

if [ "$TARGET" = wayland ] && [ "$RENDERER" = software ]; then
  LINK_LIBS=(-L "-static"
             -L "-L$DEPS_PREFIX/lib64"
             -L "-L$DEPS_PREFIX/lib"
             "${LINK_LIBS[@]}")
fi

# Compile raylib bindings as a separate unit.
# -d1 (not -d0) is required so eval/REPL can resolve module exports at runtime.
"$CSC" -O3 -d1 -static \
       -cc "$CC_BUILD" \
       -C "-I$RAYLIB_SRC" \
       -J \
       -c "$ROOT/raylib.scm" \
       -o "$BUILD/raylib.o"

# csc's find-object-file searches cwd for raylib.o (matching the unit referenced
# via runtime.scm's (declare (uses raylib))). Run the link step from $BUILD.
cd "$BUILD"
"$CSC" -O3 -d1 -static \
       -cc "$CC_BUILD" \
       -I "$BUILD" \
       -I "$ROOT" \
       -C "-I$RAYLIB_SRC" \
       -L "$RAYLIB_SRC/libraylib.a" \
       -link matchable \
       -link miscmacros \
       -link record-variants \
       -link coops \
       -link coops-primitive-objects \
       "${LINK_LIBS[@]}" \
       "$ROOT/runtime.scm" \
       -o "$APP_NAME"
cd "$ROOT"

log "Built: $BUILD/$APP_NAME"
file "$BUILD/$APP_NAME"
echo
echo "Dynamic deps:"
INTERP="$(LC_ALL=C file "$BUILD/$APP_NAME" | sed -n 's/.*interpreter \([^,]*\).*/\1/p')"
if [ -n "$INTERP" ] && [ -x "$INTERP" ] &&
   { printf '%s\n' "$INTERP" | grep -qi musl ||
     LC_ALL=C file "$INTERP" | grep -qi musl; }; then
  "$INTERP" --list "$BUILD/$APP_NAME" 2>&1 | sed 's/^/  /' || true
else
  ldd "$BUILD/$APP_NAME" 2>&1 | sed 's/^/  /' || true
fi
