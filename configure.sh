#!/bin/bash
# Bootstrap a fresh checkout: install system tools, fetch sources, apply patches.
# After this finishes you can: ./build.sh wayland   (or:  ./build.sh x11)
#
# Distros covered: Fedora/RHEL, Debian/Ubuntu, Arch, openSUSE, Alpine.
# Other distros: prints the package list it would install; install manually
# and re-run with SKIP_SYSTEM_PACKAGES=1.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Pinned source versions
CHICKEN_VERSION=5.4.0
RAYLIB_VERSION=6.0
LIBFFI_VERSION=3.5.2
WAYLAND_VERSION=1.24.0
XKBCOMMON_VERSION=1.11.0

CHICKEN_URL="https://code.call-cc.org/releases/${CHICKEN_VERSION}/chicken-${CHICKEN_VERSION}.tar.gz"
RAYLIB_URL="https://github.com/raysan5/raylib.git"
LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
WAYLAND_URL="https://gitlab.freedesktop.org/wayland/wayland/-/releases/${WAYLAND_VERSION}/downloads/wayland-${WAYLAND_VERSION}.tar.xz"
XKBCOMMON_URL="https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-${XKBCOMMON_VERSION}.tar.gz"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# 1. Detect distro and install system packages
# ----------------------------------------------------------------------------

detect_distro() {
  if [ ! -f /etc/os-release ]; then echo unknown; return; fi
  . /etc/os-release
  local ids="${ID:-} ${ID_LIKE:-}"
  case " $ids " in
    *" fedora "*|*" rhel "*|*" centos "*) echo fedora ;;
    *" debian "*|*" ubuntu "*)            echo debian ;;
    *" arch "*)                           echo arch ;;
    *" suse "*|*" opensuse "*)            echo suse ;;
    *" alpine "*)                         echo alpine ;;
    *) echo unknown ;;
  esac
}

sudo_cmd() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; return; fi
  if ! command -v sudo >/dev/null; then
    die "Need to install packages but neither root nor sudo is available."
  fi
  sudo "$@"
}

install_packages() {
  local distro=$1
  case $distro in
    fedora)
      sudo_cmd dnf install -y \
        musl-gcc musl-libc-static musl-devel \
        gcc make \
        meson ninja-build bison flex pkgconf-pkg-config \
        wayland-devel libxkbcommon-devel libffi-devel \
        libX11-devel libXrandr-devel libXi-devel libXcursor-devel libXinerama-devel \
        kernel-headers \
        curl tar xz gzip git
      ;;
    debian)
      sudo_cmd apt-get update
      sudo_cmd apt-get install -y \
        musl-tools \
        gcc make \
        meson ninja-build bison flex pkg-config \
        libwayland-dev libwayland-bin libxkbcommon-dev libffi-dev \
        libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
        linux-libc-dev \
        curl tar xz-utils gzip git
      ;;
    arch)
      sudo_cmd pacman -S --needed --noconfirm \
        musl \
        base-devel meson ninja \
        wayland libxkbcommon libffi \
        libx11 libxrandr libxi libxcursor libxinerama \
        curl tar xz gzip git
      ;;
    suse)
      sudo_cmd zypper install -y \
        musl-libc musl-libc-static musl-libc-devel \
        gcc make \
        meson ninja bison flex pkg-config \
        wayland-devel libxkbcommon-devel libffi-devel \
        libX11-devel libXrandr-devel libXi-devel libXcursor-devel libXinerama-devel \
        linux-glibc-devel \
        curl tar xz gzip git
      ;;
    alpine)
      # Alpine *is* musl. Use plain gcc as both system and "musl" compiler.
      sudo_cmd apk add --no-cache \
        gcc musl-dev make \
        meson ninja samurai bison flex pkgconf \
        wayland-dev libxkbcommon-dev libffi-dev \
        libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
        linux-headers \
        curl tar xz gzip git
      ;;
    *)
      warn "Unknown distro. Install these tools manually, then re-run with SKIP_SYSTEM_PACKAGES=1:"
      cat <<'PKGS' >&2
  Required:
    - musl-gcc (or, on Alpine, plain gcc since libc is already musl)
    - musl static libc + headers
    - gcc, make
    - meson, ninja
    - bison, flex
    - pkg-config
    - wayland (devel + wayland-scanner)
    - libxkbcommon (devel)
    - libffi (devel)
    - kernel UAPI headers (linux/input.h)
    - curl, tar, xz, gzip, git
  Optional (for x11 target):
    - libX11, libXrandr, libXi, libXcursor, libXinerama (devel)
PKGS
      die "Bailing out."
      ;;
  esac
}

# ----------------------------------------------------------------------------
# 2. Source fetch + extract
# ----------------------------------------------------------------------------

fetch_chicken() {
  if [ -d "$ROOT/chicken-${CHICKEN_VERSION}" ]; then
    log "CHICKEN ${CHICKEN_VERSION} already extracted, skipping."
    return
  fi
  if [ ! -f "$ROOT/chicken-${CHICKEN_VERSION}.tar.gz" ]; then
    log "Fetching CHICKEN ${CHICKEN_VERSION}"
    curl -fsSL -o "$ROOT/chicken-${CHICKEN_VERSION}.tar.gz" "$CHICKEN_URL"
  fi
  log "Extracting CHICKEN"
  tar -xzf "$ROOT/chicken-${CHICKEN_VERSION}.tar.gz" -C "$ROOT"
}

fetch_raylib() {
  local target="$ROOT/vendor/raylib"
  if [ -d "$target/.git" ]; then
    log "raylib already cloned, skipping."
  else
    log "Cloning raylib ${RAYLIB_VERSION}"
    mkdir -p "$ROOT/vendor"
    git clone --depth 1 --branch "$RAYLIB_VERSION" "$RAYLIB_URL" "$target"
  fi

  # Apply local patches
  for p in "$ROOT/patches"/*.patch; do
    [ -f "$p" ] || continue
    if (cd "$target" && git apply --check --reverse "$p" >/dev/null 2>&1); then
      log "Patch already applied: $(basename "$p")"
    else
      log "Applying patch: $(basename "$p")"
      (cd "$target" && git apply "$p")
    fi
  done
}

fetch_deps() {
  local d="$ROOT/vendor/deps"
  mkdir -p "$d/src"

  if [ ! -d "$d/src/libffi-${LIBFFI_VERSION}" ]; then
    log "Fetching libffi ${LIBFFI_VERSION}"
    curl -fsSL -o "$d/libffi-${LIBFFI_VERSION}.tar.gz" "$LIBFFI_URL"
    tar -xzf "$d/libffi-${LIBFFI_VERSION}.tar.gz" -C "$d/src"
  fi

  if [ ! -d "$d/src/wayland-${WAYLAND_VERSION}" ]; then
    log "Fetching wayland ${WAYLAND_VERSION}"
    curl -fsSL -o "$d/wayland-${WAYLAND_VERSION}.tar.xz" "$WAYLAND_URL"
    tar -xJf "$d/wayland-${WAYLAND_VERSION}.tar.xz" -C "$d/src"
  fi

  if [ ! -d "$d/src/libxkbcommon-xkbcommon-${XKBCOMMON_VERSION}" ]; then
    log "Fetching libxkbcommon ${XKBCOMMON_VERSION}"
    curl -fsSL -o "$d/libxkbcommon-${XKBCOMMON_VERSION}.tar.gz" "$XKBCOMMON_URL"
    tar -xzf "$d/libxkbcommon-${XKBCOMMON_VERSION}.tar.gz" -C "$d/src"
  fi
}

# ----------------------------------------------------------------------------
# Drive
# ----------------------------------------------------------------------------

distro=$(detect_distro)
log "Detected distro: $distro"

if [ "${SKIP_SYSTEM_PACKAGES:-0}" = 1 ]; then
  log "Skipping system package install (SKIP_SYSTEM_PACKAGES=1)"
else
  install_packages "$distro"
fi

# Provide a musl-gcc shim on Alpine where libc *is* musl
if [ "$distro" = alpine ] && ! command -v musl-gcc >/dev/null; then
  log "Alpine: shimming musl-gcc -> gcc into ./bin/"
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/musl-gcc" <<'SHIM'
#!/bin/sh
exec gcc "$@"
SHIM
  chmod +x "$ROOT/bin/musl-gcc"
  warn "Add $ROOT/bin to your PATH, or run: export PATH=\"$ROOT/bin:\$PATH\""
fi

fetch_chicken
fetch_raylib
fetch_deps

# CHICKEN eggs needed at compile time (TCP REPL, hash tables, list utils, threads).
# Install into the musl-built CHICKEN's repo. Build the runtime first if missing.
install_eggs() {
  if [ ! -x "$ROOT/chicken-musl/bin/chicken-install" ]; then
    log "CHICKEN not yet built — eggs will be installed on first ./build.sh."
    return
  fi
  for egg in srfi-1 srfi-18 srfi-69 utf8 symbol-utils check-errors apropos; do
    if [ ! -f "$ROOT/chicken-musl/lib/chicken/11/${egg}.import.so" ]; then
      log "Installing CHICKEN egg: $egg"
      (cd /tmp && "$ROOT/chicken-musl/bin/chicken-install" "$egg") \
        || warn "Failed to install $egg — needs network access."
    fi
  done
}
install_eggs

log "configure.sh done. Now run:  ./build.sh wayland   (or  ./build.sh x11)"
