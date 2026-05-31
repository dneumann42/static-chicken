#!/bin/bash
# Build libffi, wayland-client, and libxkbcommon as static musl libs into
# third_party/native/deps/prefix. Invoked once before build.sh wayland.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/third_party/native/deps"
SRC="$DEPS/src"
PREFIX="$DEPS/prefix"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$PREFIX/lib" "$PREFIX/include"

# Tell musl-gcc to also look at /usr/include for kernel UAPI (linux/*).
export CC="musl-gcc"
export CFLAGS="${CFLAGS:-} -idirafter /usr/include -O2"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig"

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

write_wayland_scanner_pc() {
  local scanner
  scanner="$(command -v wayland-scanner)" || return 0

  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/wayland-scanner.pc" <<PC
prefix=$PREFIX
bindir=\${prefix}/bin
datarootdir=\${prefix}/share
pkgdatadir=\${datarootdir}/wayland
wayland_scanner=$scanner

Name: Wayland Scanner
Description: Wayland scanner
Version: 1.24.0
PC
}

# 1. libffi (autotools)
if [ ! -f "$PREFIX/lib/libffi.a" ]; then
  log "Building libffi (musl-static)"
  cd "$SRC/libffi-3.5.2"
  if [ ! -f config.status ]; then
    ./configure --prefix="$PREFIX" \
                --disable-shared --enable-static \
                --disable-multi-os-directory \
                --disable-docs
  fi
  make -j"$JOBS"
  make install
fi

# 2. wayland (meson) — client+cursor+egl static libs only; system scanner is fine
if [ ! -f "$PREFIX/lib/libwayland-client.a" ]; then
  log "Building wayland 1.24 (musl-static, client only)"
  write_wayland_scanner_pc
  cd "$SRC/wayland-1.24.0"
  rm -rf build
  meson setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=static \
    -Ddocumentation=false \
    -Dtests=false \
    -Ddtd_validation=false \
    -Dscanner=false \
    -Dlibraries=true
  ninja -C build -j"$JOBS" install
fi

# 3. libxkbcommon (meson) — minimal
if [ ! -f "$PREFIX/lib/libxkbcommon.a" ]; then
  log "Building libxkbcommon 1.11 (musl-static)"
  cd "$SRC/libxkbcommon-xkbcommon-1.11.0"
  rm -rf build
  meson setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=static \
    -Denable-x11=false \
    -Denable-wayland=false \
    -Denable-docs=false \
    -Denable-tools=false \
    -Denable-xkbregistry=false \
    -Dxkb-config-root=/usr/share/X11/xkb
  ninja -C build -j"$JOBS" libxkbcommon.a
  meson install -C build --no-rebuild
fi

log "Done. Static libs in $PREFIX/lib:"
ls "$PREFIX/lib"/*.a
