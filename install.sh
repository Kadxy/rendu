#!/bin/sh
# Install the rendu CLI from GitHub Releases (macOS, Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/Kadxy/rendu/main/install.sh | sh
#
# RENDU_VERSION      a release tag such as v0.1.0 (default: latest)
# RENDU_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
set -eu

repo=Kadxy/rendu
dir=${RENDU_INSTALL_DIR:-$HOME/.local/bin}

fail() {
	echo "rendu install: $*" >&2
	exit 1
}

case $(uname -s) in
Darwin) os=darwin ;;
Linux) os=linux ;;
*) fail "unsupported OS $(uname -s); download a build from https://github.com/$repo/releases" ;;
esac
case $(uname -m) in
x86_64 | amd64) arch=amd64 ;;
arm64 | aarch64) arch=arm64 ;;
*) fail "unsupported architecture $(uname -m)" ;;
esac

if [ -n "${RENDU_VERSION:-}" ]; then
	base=https://github.com/$repo/releases/download/$RENDU_VERSION
else
	base=https://github.com/$repo/releases/latest/download
fi
archive=rendu_${os}_${arch}.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$archive" "$base/$archive" || fail "download failed: $base/$archive"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" || fail "download failed: $base/checksums.txt"

want=$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/checksums.txt")
if command -v sha256sum >/dev/null 2>&1; then
	got=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
else
	got=$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')
fi
[ -n "$want" ] && [ "$got" = "$want" ] || fail "checksum mismatch for $archive"

tar -xzf "$tmp/$archive" -C "$tmp" rendu
mkdir -p "$dir"
install -m 755 "$tmp/rendu" "$dir/rendu"
echo "Installed $("$dir/rendu" --version) to $dir/rendu"

case ":$PATH:" in
*":$dir:"*) ;;
*) echo "Add $dir to your PATH, e.g.: export PATH=\"$dir:\$PATH\"" ;;
esac
