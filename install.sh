#!/bin/sh
# Install the jurisdictional CLI from a GitHub release.
#
#   curl -fsSL https://github.com/afomi/jurisdictional-cli/releases/latest/download/install.sh | sh
#
# Environment:
#   JURISDICTIONAL_VERSION      release tag to install, e.g. v0.1.0 (default: latest)
#   JURISDICTIONAL_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
#   JURISDICTIONAL_BASE_URL     download from this URL instead of GitHub (mirrors, testing)
#
# The binary is an escript, so it needs Erlang/OTP 26 or newer on this machine.
set -eu

repo="afomi/jurisdictional-cli"
version="${JURISDICTIONAL_VERSION:-latest}"
dir="${JURISDICTIONAL_INSTALL_DIR:-$HOME/.local/bin}"

fail() { echo "jurisdictional install: $*" >&2; exit 1; }

if [ -n "${JURISDICTIONAL_BASE_URL:-}" ]; then
  base="$JURISDICTIONAL_BASE_URL"
elif [ "$version" = "latest" ]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/$version"
fi

command -v erl >/dev/null 2>&1 || fail "Erlang/OTP 26+ is required. Install it first, e.g. 'brew install erlang' or 'apt install erlang'."

otp=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo 0)
[ "$otp" -ge 26 ] 2>/dev/null || fail "found Erlang/OTP $otp; version 26 or newer is required."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading jurisdictional ($version)..."
curl -fsSL "$base/jurisdictional" -o "$tmp/jurisdictional" || fail "download failed from $base/jurisdictional"
curl -fsSL "$base/jurisdictional.sha256" -o "$tmp/jurisdictional.sha256" || fail "checksum download failed"

expected=$(awk '{print $1}' "$tmp/jurisdictional.sha256")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/jurisdictional" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/jurisdictional" | awk '{print $1}')
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch (expected $expected, got $actual)"

mkdir -p "$dir"
install -m 755 "$tmp/jurisdictional" "$dir/jurisdictional"

# Confirm the installed file actually runs, not just that it was copied.
"$dir/jurisdictional" help | grep -q "client for the Jurisdictional HTTP API" \
  || fail "installed $dir/jurisdictional but it did not run"

echo "Installed $dir/jurisdictional"
case ":$PATH:" in
  *":$dir:"*) echo "Try: jurisdictional juricode \"Vacaville, CA\"" ;;
  *) echo "Add $dir to your PATH, then try: jurisdictional juricode \"Vacaville, CA\"" ;;
esac
