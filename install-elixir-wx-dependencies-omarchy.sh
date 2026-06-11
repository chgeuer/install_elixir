#!/usr/bin/env bash
#
# install-elixir-wx-dependencies-omarchy.sh
#
# Make Erlang's :observer / wx GUI work with the *prebuilt* OTP releases
# (from github.com/erlef/otp_builds, installed via ~/install-elixir.sh into
# ~/.elixir-install) on Omarchy / Arch Linux.
#
# ── The problem ──────────────────────────────────────────────────────────────
# The prebuilt OTP is compiled on Ubuntu, where wxWidgets 3.2 uses the X11/GLX
# GLCanvas backend and *versioned* symbols. Its wx NIF therefore needs e.g.
#   _ZNK13wxGLCanvasX1115IsShownOnScreenEv  (wxGLCanvasX11::IsShownOnScreen)  @WXU_3.2
# Omarchy's `wxwidgets-gtk3` is built with the *EGL* backend (wxGLCanvasEGL) and
# with no symbol versioning, so those symbols simply do not exist and the NIF
# fails to load:
#   undefined symbol: _ZNK13wxGLCanvasX1115IsShownOnScreenEv, version WXU_3.2
#
# ── The fix (this script) ────────────────────────────────────────────────────
# No compiling, no rebuilding OTP/Elixir, no touching the system wxWidgets:
#   1. Download the matching *prebuilt* Ubuntu wxWidgets 3.2 runtime libs
#      (X11/GLX backend, WXU_3.2 versioned symbols) into a private directory
#      under ~/.elixir-install/wx-compat/lib  (does NOT affect any other app).
#   2. patchelf each OTP wx NIF's RPATH to load wx from that private dir.
#      => scoped to the BEAM only; no LD_LIBRARY_PATH / no global side effects.
#
# Idempotent: safe to re-run. Run it again after installing a new Elixir/OTP.
#
# Usage:
#   ./install-elixir-wx-dependencies-omarchy.sh [--force] [--help]
#
# Env overrides:
#   ELIXIR_INSTALL_ROOT   default: ~/.elixir-install
#   WX_DEB_VERSION        pin a specific Ubuntu wx version (e.g. 3.2.6+dfsg-2ubuntu1)
#   FORCE=1               same as --force (re-download compat libs)
#
set -euo pipefail

# ── configuration ────────────────────────────────────────────────────────────
ELIXIR_INSTALL_ROOT="${ELIXIR_INSTALL_ROOT:-$HOME/.elixir-install}"
OTP_INSTALLS_DIR="$ELIXIR_INSTALL_ROOT/installs/otp"
COMPAT_DIR="$ELIXIR_INSTALL_ROOT/wx-compat"
COMPAT_LIB="$COMPAT_DIR/lib"
VERSION_MARKER="$COMPAT_DIR/.wx-deb-version"

WX_SERIES="3.2"   # wx ABI series the prebuilt NIFs link against
POOL_BASE="http://archive.ubuntu.com/ubuntu/pool/universe/w/wxwidgets3.2/"
# Source package wxwidgets3.2 produces these runtime binary packages (amd64):
PKG_BASE="libwxbase3.2-1t64"     # libwx_baseu*  (non-GUI core)
PKG_GTK="libwxgtk3.2-1t64"       # libwx_gtk3u_* (GUI widgets)
PKG_GL="libwxgtk-gl3.2-1t64"     # libwx_gtk3u_gl (the X11/GLCanvas lib we need)

FORCE="${FORCE:-0}"
for arg in "${@:-}"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    "") ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ── logging helpers ──────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 0. sanity checks ─────────────────────────────────────────────────────────
command -v pacman >/dev/null 2>&1 || die "This script targets Arch/Omarchy (pacman not found)."
[ -d "$OTP_INSTALLS_DIR" ] || die "No OTP installs found at $OTP_INSTALLS_DIR — install Elixir/OTP first."

# ── 1. ensure host tooling (no compilers; just unpack + patch) ───────────────
log "Checking host tooling"
declare -a need=()
command -v patchelf >/dev/null 2>&1 || need+=(patchelf)
command -v curl     >/dev/null 2>&1 || need+=(curl)
command -v zstd     >/dev/null 2>&1 || need+=(zstd)
command -v ar       >/dev/null 2>&1 || need+=(binutils)
command -v objdump  >/dev/null 2>&1 || need+=(binutils)
if ((${#need[@]})); then
  mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
  log "Installing: ${need[*]}"
  sudo pacman -S --needed --noconfirm "${need[@]}"
fi
ok "patchelf $(patchelf --version 2>/dev/null | awk '{print $2}'), curl, zstd, binutils present"

# ── 2. discover the OTP wx NIFs that need libwx ──────────────────────────────
log "Locating OTP wx NIFs under $OTP_INSTALLS_DIR"
declare -a NIFS=()
while IFS= read -r so; do
  if objdump -p "$so" 2>/dev/null | grep -qE 'NEEDED\s+libwx_'; then
    NIFS+=("$so")
  fi
done < <(find "$OTP_INSTALLS_DIR" -type f -path '*/lib/wx-*/priv/*.so' 2>/dev/null | sort)

[ "${#NIFS[@]}" -gt 0 ] || die "No wx NIFs that link libwx were found. Nothing to do."
for so in "${NIFS[@]}"; do ok "${so/#$HOME/\~}"; done

# sanity: confirm the NIFs really want the 3.2 series (future-proofing guard)
if ! objdump -p "${NIFS[0]}" 2>/dev/null | grep -qE "NEEDED\s+libwx_[a-z0-9_]+-${WX_SERIES//./\\.}\.so"; then
  warn "NIFs do not appear to link wxWidgets ${WX_SERIES}. This script only handles ${WX_SERIES}."
  warn "Required libs: $(objdump -p "${NIFS[0]}" | awk '/NEEDED.*libwx_/{print $2}' | tr '\n' ' ')"
  die  "Aborting to avoid installing a mismatched wx series."
fi

# ── 3. resolve which Ubuntu wx version to fetch ──────────────────────────────
resolve_version() {
  if [ -n "${WX_DEB_VERSION:-}" ]; then echo "$WX_DEB_VERSION"; return 0; fi
  local listing; listing="$(curl -fsSL --max-time 30 "$POOL_BASE")" || return 1
  # versions for which ALL THREE packages exist (plain amd64, not amd64v3),
  # newest first.
  local v
  for v in $(printf '%s' "$listing" \
              | grep -oE "${PKG_GL}_[^\"]+_amd64\.deb" \
              | sed -E "s/^${PKG_GL}_//; s/_amd64\.deb$//" \
              | sort -Vr -u); do
    if printf '%s' "$listing" | grep -q "${PKG_BASE}_${v}_amd64.deb" \
    && printf '%s' "$listing" | grep -q "${PKG_GTK}_${v}_amd64.deb"; then
      echo "$v"; return 0
    fi
  done
  return 1
}

log "Resolving matching Ubuntu wxWidgets ${WX_SERIES} version"
WX_VER="$(resolve_version)" || die "Could not determine a wx version from $POOL_BASE"
ok "Using wxWidgets $WX_VER"

# ── 4. download + extract the prebuilt libs (idempotent) ─────────────────────
have_libs() { [ -e "$COMPAT_LIB/libwx_gtk3u_gl-${WX_SERIES}.so.0" ] \
           && [ -e "$COMPAT_LIB/libwx_gtk3u_core-${WX_SERIES}.so.0" ] \
           && [ -e "$COMPAT_LIB/libwx_baseu-${WX_SERIES}.so.0" ]; }

if [ "$FORCE" != "1" ] && have_libs && [ "$(cat "$VERSION_MARKER" 2>/dev/null || true)" = "$WX_VER" ]; then
  log "Compat wx libs already present ($WX_VER) — skipping download (use --force to refresh)"
else
  log "Downloading + extracting prebuilt wx libs into ${COMPAT_LIB/#$HOME/\~}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/extract"
  for pkg in "$PKG_BASE" "$PKG_GTK" "$PKG_GL"; do
    deb="${pkg}_${WX_VER}_amd64.deb"
    log "  fetch $deb"
    curl -fsSL --max-time 180 -o "$tmp/$deb" "${POOL_BASE}${deb}" \
      || die "download failed: ${POOL_BASE}${deb}"
    data="$(ar t "$tmp/$deb" | grep '^data.tar')"
    ar p "$tmp/$deb" "$data" > "$tmp/data.bin"
    case "$data" in
      *.zst) zstd -dqf "$tmp/data.bin" -o "$tmp/data.tar" ;;
      *.xz)  xz   -dcf "$tmp/data.bin" >  "$tmp/data.tar" ;;
      *.gz)  gzip -dcf "$tmp/data.bin" >  "$tmp/data.tar" ;;
      *)     mv "$tmp/data.bin" "$tmp/data.tar" ;;
    esac
    tar -C "$tmp/extract" -xf "$tmp/data.tar"
  done

  rm -rf "$COMPAT_LIB"
  mkdir -p "$COMPAT_LIB"
  cp -a "$tmp"/extract/usr/lib/*/libwx_*.so* "$COMPAT_LIB"/
  echo "$WX_VER" > "$VERSION_MARKER"

  # let each wx lib find its siblings in its own directory (so no env var needed)
  find "$COMPAT_LIB" -maxdepth 1 -type f -name 'libwx_*.so*' \
    -exec patchelf --set-rpath '$ORIGIN' --force-rpath {} \;
  ok "$(find "$COMPAT_LIB" -maxdepth 1 -type f -name 'libwx_*.so*' | wc -l) wx libraries staged"
fi

# verify the one symbol that was failing is actually present now
if ! objdump -T "$COMPAT_LIB/libwx_gtk3u_gl-${WX_SERIES}.so.0" 2>/dev/null \
     | grep -q 'wxGLCanvasX11.*IsShownOnScreen'; then
  die "Staged wx GL lib lacks the X11 GLCanvas symbols — wrong/unsuitable wx build."
fi
ok "X11 GLCanvas symbols present in staged wx GL lib"

# ── 5. point each OTP wx NIF at the compat libs (scoped RPATH) ────────────────
log "Patching OTP wx NIFs to use the compat libs (scoped RPATH, no env vars)"
for so in "${NIFS[@]}"; do
  patchelf --set-rpath "$COMPAT_LIB" --force-rpath "$so"
  ok "rpath set: ${so/#$HOME/\~}"
done

# ── 6. verify ────────────────────────────────────────────────────────────────
log "Verifying symbol resolution"
fail=0
for so in "${NIFS[@]}"; do
  missing_lib="$(ldd "$so" 2>&1 | grep -E 'libwx_.* => not found' || true)"
  # Inspect only the *symbol name* (not the file path, which contains "wx").
  # enif_*/driver_*/erl_drv_* are provided by the BEAM at load time and are
  # always "undefined" in ldd -r — only wx-mangled symbols (…wx…) matter here.
  wx_undef="$(ldd -r "$so" 2>&1 \
              | grep -oE 'undefined symbol: [A-Za-z0-9_]+' \
              | awk '{print $3}' | grep -i 'wx' || true)"
  if [ -n "$missing_lib" ] || [ -n "$wx_undef" ]; then
    warn "PROBLEM in ${so/#$HOME/\~}"
    [ -n "$missing_lib" ] && printf '%s\n' "$missing_lib" | sed 's/^/      /'
    [ -n "$wx_undef" ]    && printf '%s\n' "$wx_undef"    | sed 's/^/      /'
    fail=1
  else
    resolved="$(ldd "$so" 2>&1 | awk '/libwx_gtk3u_gl/{print $3}')"
    ok "${so##*/}: wx symbols resolved (gl => ${resolved:-?})"
  fi
done
[ "$fail" -eq 0 ] || die "Verification failed — see problems above."

# ── 7. optional runtime smoke test (only if a display is available) ──────────
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  newest_erl="$(find "$OTP_INSTALLS_DIR" -type f -path '*/bin/erl' 2>/dev/null | sort -V | tail -n1)"
  if [ -n "$newest_erl" ]; then
    log "Runtime smoke test: starting/stopping wx via $newest_erl"
    if "$newest_erl" -noshell -eval \
        '_=wx:new(), wx:destroy(), io:format("WX_OK~n",[]), halt(0).' 2>/dev/null \
        | grep -q WX_OK; then
      ok "wx:new() works — :observer.start() is ready to use"
    else
      warn "wx:new() smoke test did not confirm (display/session issue?) — try :observer.start() in iex"
    fi
  fi
else
  warn "No DISPLAY/WAYLAND_DISPLAY in this shell — skipping runtime smoke test"
fi

# ── done ─────────────────────────────────────────────────────────────────────
cat <<EOF

$(printf '\033[1;32m✓ wxWidgets dependencies for Erlang :observer are installed.\033[0m')

  Compat libs : ${COMPAT_LIB/#$HOME/\~}   (wxWidgets $WX_VER, private to the BEAM)
  Patched NIFs: ${#NIFS[@]}
  System wx   : untouched (other apps unaffected; no LD_LIBRARY_PATH needed)

  Try it:   iex  ->  :observer.start()

  Re-run this script after installing a new Elixir/OTP version
  (it will detect and patch the new NIFs). Re-run with --force to
  refresh the downloaded wx libraries.
EOF
