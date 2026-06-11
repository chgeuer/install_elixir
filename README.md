# install_elixir

Install **prebuilt** Elixir and Erlang/OTP releases on **Omarchy / Arch Linux** —
and make Erlang's `:observer` GUI actually work there.

The official [`elixir-lang.org` install script](https://elixir-lang.org/install.html#install-scripts)
downloads prebuilt OTP/Elixir binaries (from
[`erlef/otp_builds`](https://github.com/erlef/otp_builds)) into `~/.elixir-install`.
Those binaries are built on Ubuntu, so two things break on Arch:

1. The installer **refuses to run** because the distro isn't Ubuntu.
2. Even once installed, `:observer.start()` **crashes** because the prebuilt `wx`
   NIF links against Ubuntu's X11/GLX wxWidgets, while Arch ships an
   incompatible EGL build.

This repo fixes both, **without compiling anything** and **without touching your
system wxWidgets**.

## What's inside

| File | Purpose |
| --- | --- |
| [`install-elixir.sh`](./install-elixir.sh) | The upstream [`elixir-lang` `install.sh`](https://github.com/elixir-lang/elixir-lang.github.com/blob/main/install.sh) with the "not Ubuntu → abort" guard disabled so it runs on Arch. Installs a specific Elixir + OTP version. |
| [`install-elixir-latest.sh`](./install-elixir-latest.sh) | Resolves the latest published Elixir and OTP versions from GitHub, installs them, then applies the `wx` fix. The convenient one-shot entry point. |
| [`install-elixir-wx-dependencies-omarchy.sh`](./install-elixir-wx-dependencies-omarchy.sh) | Patches the prebuilt OTP `wx` NIFs so `:observer` works on Omarchy/Arch. Idempotent. |
| [`omarchy_elixir_wx_observer.md`](./omarchy_elixir_wx_observer.md) | Deep-dive write-up of the `:observer`/wxWidgets problem and the fix. |

## Quick start

Install the latest Elixir + OTP and apply the `:observer` fix in one go:

```bash
./install-elixir-latest.sh
```

Then add the printed paths to your shell profile (see [Add to your PATH](#add-to-your-path)),
open `iex`, and confirm the GUI works:

```elixir
iex> :observer.start()   # 🎉
```

## Usage

### Install the latest release (recommended)

```bash
./install-elixir-latest.sh
```

This script:

1. Looks up the newest **published** (non-prerelease) Elixir and OTP versions via
   each project's `releases/latest` redirect on GitHub.
2. Calls `install-elixir.sh elixir@<latest> otp@<latest>`.
3. Runs `install-elixir-wx-dependencies-omarchy.sh` to patch the freshly
   installed `wx` NIFs.

To **pin** specific versions instead, edit the two version lines near the bottom
of the script:

```bash
elixir_version=1.20.0-rc.5 ; otp_version=28.4
```

### Install a specific version

```bash
./install-elixir.sh elixir@1.18.3 otp@27.2
```

`ELIXIR_VERSION` can be `X.Y.Z`, `latest`, or `main`.
`OTP_VERSION` can be `X.Y.Z`, `latest`, `master`, `maint`, or `maint-RELEASE`
(e.g. `maint-27`). Pass `-f`/`--force` to reinstall, `-h`/`--help` for details.

> This is the upstream installer. The **only** local change is commenting out the
> `exit 1` in the non-Ubuntu guard, so the Ubuntu-built binaries install on Arch.
> It also supports macOS and Windows (MINGW), unchanged from upstream.

### Fix `:observer` / wxWidgets only

If you installed Elixir/OTP some other way and just need the GUI fix:

```bash
./install-elixir-wx-dependencies-omarchy.sh           # patch
./install-elixir-wx-dependencies-omarchy.sh --force   # re-download compat libs
./install-elixir-wx-dependencies-omarchy.sh --help
```

What it does (no compilers, no rebuild, no system changes):

1. Finds every OTP `wx` NIF under `~/.elixir-install/installs/otp/*`.
2. Auto-discovers and downloads the matching prebuilt **Ubuntu wxWidgets 3.2**
   runtime libs (X11/GLX backend, `WXU_3.2` versioned symbols) into a private
   dir: `~/.elixir-install/wx-compat/lib`.
3. Rewrites each NIF's `RPATH` with `patchelf` to load wx from that private dir —
   scoped to the BEAM only, so **no `LD_LIBRARY_PATH`** and **no global side
   effects**. Every other wx app keeps using the system EGL build.
4. Verifies symbol resolution and runs a `wx:new()` smoke test if a display is
   available.

Environment overrides: `ELIXIR_INSTALL_ROOT` (default `~/.elixir-install`),
`WX_DEB_VERSION` (pin a specific Ubuntu wx version), `FORCE=1` (same as `--force`).

See [`omarchy_elixir_wx_observer.md`](./omarchy_elixir_wx_observer.md) for the full
root-cause analysis.

## Add to your PATH

After installation, `install-elixir.sh` prints the exact lines to add. Add them to
your `~/.bashrc` (or equivalent), substituting the versions you installed:

```bash
export PATH=$HOME/.elixir-install/installs/otp/<otp_version>/bin:$PATH
export PATH=$HOME/.elixir-install/installs/elixir/<elixir_version>-otp-<otp_release>/bin:$PATH
```

## Upgrading

Just run `./install-elixir-latest.sh` again. A freshly downloaded OTP ships an
**unpatched** `wx` NIF, so the wx fix must be reapplied after every upgrade — the
script is idempotent and only patches newly installed NIFs. The compat libs are
shared across OTP 27/28/29 (all use the wx `3.2` ABI).

## Requirements

- Arch / Omarchy (uses `pacman`); the wx fix targets Arch specifically.
- `curl`. The wx fix additionally needs `patchelf`, `zstd`, and `binutils`
  (`ar`/`objdump`) — it installs any that are missing via `pacman`.

## Credits

- The base installer is the official
  [elixir-lang install script](https://github.com/elixir-lang/elixir-lang.github.com/blob/main/install.sh).
- Prebuilt OTP/Elixir binaries come from
  [`erlef/otp_builds`](https://github.com/erlef/otp_builds).

## License

[MIT](./LICENSE) © Dr. Christian Geuer-Pollmann
