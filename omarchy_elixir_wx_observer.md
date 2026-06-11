# Making Erlang's `:observer` work on Omarchy / Arch Linux

If you install Elixir and Erlang/OTP from the **prebuilt GitHub releases** (the
`erlef/otp_builds` binaries that the official `elixir-lang.org` `install.sh`
downloads into `~/.elixir-install`), then open `iex` on an Omarchy machine and run:

```elixir
iex> :observer.start()
```

…it blows up instead of opening the GUI:

```
[error] WX ERROR: Could not load library: :load_failed
Failed to load NIF library: '.../lib/wx-2.6/priv/wxe_driver.so:
  undefined symbol: _ZNK13wxGLCanvasX1115IsShownOnScreenEv, version WXU_3.2'
```

Here is *why* it happens and a clean, no-compile fix.

## TL;DR

```bash
./install-elixir-wx-dependencies-omarchy.sh
iex
iex> :observer.start()   # 🎉
```

The script downloads the *matching* prebuilt wxWidgets libraries and points the
BEAM at them via a scoped `RPATH`. No compiling, no rebuilding OTP, no touching
your system wxWidgets. Re-run it after every Elixir/OTP upgrade.

---

## The root cause: two incompatible wxWidgets builds

The demangled missing symbol is `wxGLCanvasX11::IsShownOnScreen() const`,
tagged with the version `WXU_3.2`. Two things are going on at once:

1. **GLCanvas backend mismatch.** The prebuilt OTP is compiled on **Ubuntu**,
   where wxWidgets 3.2 uses the **X11/GLX** OpenGL-canvas backend. Its `wx` NIF
   therefore references `wxGLCanvasX11::*` symbols. Omarchy's `wxwidgets-gtk3`
   package is built with the **EGL** backend for Wayland — it ships
   `wxGLCanvasEGL` instead and has **zero** `wxGLCanvasX11` symbols.

2. **Symbol versioning mismatch.** Ubuntu's wxWidgets exports *versioned*
   symbols (`WXU_3.2`); Arch's are unversioned. (This one is harmless on its
   own — glibc happily binds a versioned reference to an unversioned definition.
   The real killer is #1: the symbol genuinely doesn't exist.)

You can see it yourself:

```bash
NIF=~/.elixir-install/installs/otp/*/lib/wx-*/priv/wxe_driver.so

# The NIF wants X11 GLCanvas symbols, versioned WXU_3.2:
objdump -T $NIF | grep wxGLCanvasX11

# Arch's wx has the EGL backend — and none of those symbols:
nm -D -C /usr/lib/libwx_gtk3u_gl-3.2.so.0 | grep -c wxGLCanvasX11   # => 0
nm -D -C /usr/lib/libwx_gtk3u_gl-3.2.so.0 | grep -c wxGLCanvasEGL   # => 21
```

**Conclusion:** no environment-variable trick against the *system* wxWidgets can
fix this. The symbols the prebuilt NIF needs simply aren't there.

## Why the obvious "fixes" don't apply

- **`pacman -S wxwidgets-gtk3`** — already installed; it's the EGL build that's
  the problem.
- **Rebuild OTP from source** — then OTP's `wx` NIF links *your* EGL wxWidgets
  and `:observer` works. But that defeats the point of using prebuilt releases.
- **`observer_cli`** — a great terminal alternative (no wx at all), but it isn't
  the GUI `:observer`.

What we want: keep the prebuilt OTP, and give it the **kind of wxWidgets it was
built against** — without disturbing the rest of the system.

## The fix: drop-in matching wx libs + a scoped RPATH

Debian/Ubuntu still build wxWidgets 3.2 with the **X11/GLX** backend and
`WXU_3.2` versioning — exactly what the OTP binary expects. So:

1. **Download** the prebuilt Ubuntu wx 3.2 runtime packages
   (`libwxbase3.2-1t64`, `libwxgtk3.2-1t64`, `libwxgtk-gl3.2-1t64`) and extract
   their `.so` files into a private dir: `~/.elixir-install/wx-compat/lib`.
2. **Point only the BEAM at them** by rewriting each OTP `wx` NIF's `RPATH`
   with `patchelf`:

   ```bash
   # each compat lib finds its siblings in its own dir…
   patchelf --set-rpath '$ORIGIN' --force-rpath wx-compat/lib/libwx_*.so*
   # …and the NIF finds the compat libs, system wx untouched:
   patchelf --set-rpath ~/.elixir-install/wx-compat/lib --force-rpath wxe_driver.so
   ```

Because `RPATH` is embedded in the NIF, there's **no `LD_LIBRARY_PATH`** and no
global side effects — every other wx app on the machine keeps using the Arch
EGL build. On amd64 the Ubuntu `t64` packages are ABI-identical to non-t64, and
the libs load cleanly against Arch's newer glibc/gtk3.

Verify with no env vars at all:

```bash
ldd -r wxe_driver.so | grep -i 'undefined symbol.*wx'   # => (empty) ✓
# only enif_* remain undefined — those are provided by the BEAM at load time.
```

## The script

[`install-elixir-wx-dependencies-omarchy.sh`](./install-elixir-wx-dependencies-omarchy.sh)
automates all of the above and is **idempotent**. It:

- installs `patchelf` (and friends) if missing — **no compilers needed**;
- finds every `wx` NIF under `~/.elixir-install/installs/otp/*`;
- auto-discovers the latest matching Ubuntu wx 3.2 version from the archive;
- downloads + extracts the libs (skips if already present; `--force` to refresh);
- patches the NIF RPATHs and verifies symbol resolution;
- runs a `wx:new()` smoke test if a display is available.

```bash
~/install-elixir-wx-dependencies-omarchy.sh
```

```
==> Locating OTP wx NIFs under ~/.elixir-install/installs/otp
  ✓ ~/.elixir-install/installs/otp/29.0.2/lib/wx-2.6/priv/wxe_driver.so
==> Using wxWidgets 3.2.9+dfsg-1
  ✓ X11 GLCanvas symbols present in staged wx GL lib
  ✓ rpath set: …/wxe_driver.so
  ✓ wxe_driver.so: wx symbols resolved
  ✓ wx:new() works — :observer.start() is ready to use
```

## Gotchas & notes

- **Re-run after every Elixir/OTP upgrade.** A freshly downloaded OTP ships an
  unpatched NIF; re-running the script detects and patches it. The compat libs
  are shared across OTP 27/28/29 (all use the wx `3.2` ABI).
- **No `GDK_BACKEND=x11` needed.** `:observer` doesn't instantiate a GL canvas,
  so it runs fine under Hyprland/Wayland. (If you build a custom wx app that
  *does* use `wxGLCanvas`, force XWayland with `GDK_BACKEND=x11`.)
- **Future wx 3.3.** If `erlef/otp_builds` ever moves to wxWidgets 3.3, the
  script refuses to install a mismatched series rather than silently breaking —
  bump it to the `wxwidgets3.3` archive pool when that day comes.
- **Prefer a terminal?** `observer_cli` (Hex) gives you most of `:observer` with
  zero GUI dependencies and is great over SSH.

---

*Environment: Omarchy 3.8.1 (Arch, rolling), Erlang/OTP 29, Elixir 1.20,
wxWidgets 3.2.10 (system, EGL) vs. 3.2.9 (compat, X11/GLX).*
