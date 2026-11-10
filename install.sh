#!/bin/sh
# Install the jurisdictional CLI from a GitHub release.
#
#   curl -fsSL https://github.com/afomi/jurisdictional-cli/releases/latest/download/install.sh | sh
#
# Installs a release that carries its own Erlang runtime, so nothing else needs
# installing. Builds exist for Linux (x86_64, arm64) and Apple silicon Macs.
#
# Environment:
#   JURISDICTIONAL_VERSION      release tag to install, e.g. v0.1.0 (default: latest)
#   JURISDICTIONAL_INSTALL_DIR  where the `jurisdictional` command goes (default: ~/.local/bin)
#   JURISDICTIONAL_HOME         where the bundled release goes (default: ~/.local/share/jurisdictional)
#   JURISDICTIONAL_BASE_URL     download from this URL instead of GitHub (mirrors, testing)
set -eu

repo="afomi/jurisdictional-cli"
version="${JURISDICTIONAL_VERSION:-latest}"
dir="${JURISDICTIONAL_INSTALL_DIR:-$HOME/.local/bin}"
home="${JURISDICTIONAL_HOME:-$HOME/.local/share/jurisdictional}"

fail() { echo "jurisdictional install: $*" >&2; exit 1; }

if [ -n "${JURISDICTIONAL_BASE_URL:-}" ]; then
  base="$JURISDICTIONAL_BASE_URL"
elif [ "$version" = "latest" ]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/$version"
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64 | Linux-amd64) target="linux-x86_64" ;;
  Linux-aarch64 | Linux-arm64) target="linux-arm64" ;;
  Darwin-arm64) target="macos-arm64" ;;
  *) fail "no build for $(uname -s) $(uname -m) yet. Build from source: https://github.com/$repo#build-from-source" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
  curl -fsSL "$base/$1" -o "$tmp/$1" || fail "download failed: $base/$1"
}

verify() {
  expected=$(awk -v f="$1" '$2 == f || $2 == "*" f {print $1}' "$tmp/SHA256SUMS")
  [ -n "$expected" ] || fail "SHA256SUMS has no entry for $1"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$1" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$tmp/$1" | awk '{print $1}')
  fi
  [ "$expected" = "$actual" ] || fail "checksum mismatch for $1 (expected $expected, got $actual)"
}

echo "Downloading jurisdictional ($version, $target)..."
fetch SHA256SUMS

archive="jurisdictional-$target.tar.gz"
fetch "$archive"
verify "$archive"

mkdir -p "$tmp/unpack"
tar -xzf "$tmp/$archive" -C "$tmp/unpack"
[ -x "$tmp/unpack/jurisdictional/bin/jurisdictional" ] || fail "$archive has no bin/jurisdictional"

mkdir -p "$(dirname "$home")"
rm -rf "$home.old"
if [ -e "$home" ]; then mv "$home" "$home.old"; fi
mv "$tmp/unpack/jurisdictional" "$home"
rm -rf "$home.old"

mkdir -p "$dir"
rm -f "$dir/jurisdictional"
ln -s "$home/bin/jurisdictional" "$dir/jurisdictional"

# Confirm the installed command actually runs, not just that it was copied.
"$dir/jurisdictional" help | grep -q "client for the Jurisdictional HTTP API" ||
  fail "installed $dir/jurisdictional but it did not run"

echo "Installed $dir/jurisdictional"
case ":$PATH:" in
  *":$dir:"*) echo "Try: jurisdictional juricode \"Vacaville, CA\"" ;;
  *) echo "Add $dir to your PATH, then try: jurisdictional juricode \"Vacaville, CA\"" ;;
esac
