#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the latest *published* (non-prerelease) version from a GitHub repo's
# "releases/latest" redirect, then strip the tag prefix.
#   $1 = owner/repo   $2 = tag prefix to strip (e.g. "OTP-" or "v")
latest_github_version() {
  local repo="$1" prefix="$2" location tag
  location="$(curl -fsS --retry 3 --head "https://github.com/${repo}/releases/latest" \
                | grep -i '^location:' | awk '{print $2}' | tr -d '\r\n')"
  [ -n "$location" ] || { echo "error: could not resolve latest release for $repo" >&2; return 1; }
  tag="$(basename "$location")"
  echo "${tag#"$prefix"}"
}

# Look up the newest versions on GitHub instead of hardcoding them.
#   Elixir : https://github.com/elixir-lang/elixir/releases/latest   (tag vX.Y.Z)
#   OTP    : https://github.com/erlef/otp_builds/releases/latest     (tag OTP-X.Y.Z)
elixir_version="$(latest_github_version elixir-lang/elixir v)"
otp_version="$(latest_github_version erlef/otp_builds OTP-)"

echo "Latest Elixir: ${elixir_version}"
echo "Latest OTP:    ${otp_version}"

# To pin specific versions instead, comment the two lines above and set e.g.:
#   elixir_version=1.20.0-rc.5 ; otp_version=28.4
"$SCRIPT_DIR/install-elixir.sh" "elixir@${elixir_version}" "otp@${otp_version}"

# Prebuilt OTP ships a wx NIF that won't load on Omarchy/Arch, so :observer
# fails until it's patched (see omarchy_elixir_wx_observer.md). Re-run after
# every upgrade — it's idempotent and only patches the newly installed NIFs.
"$SCRIPT_DIR/install-elixir-wx-dependencies-omarchy.sh"
