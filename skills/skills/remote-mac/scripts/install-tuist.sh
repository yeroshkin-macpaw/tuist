#!/usr/bin/env bash
# Installs a Tuist CLI that has `tuist sandbox sync`, unless one is on PATH already.
# Linux only: on a Mac, there is no need for a remote Mac.
#
#   TUIST_VERSION   Release to install, such as 4.220.0. Defaults to the newest CLI release.
#   TUIST_BIN_DIR   Where to put `tuist`. Defaults to ~/.local/bin.
set -euo pipefail

# Older CLIs answer an unknown subcommand's --help with the top-level help and exit 0, so look for sync in the list.
# The help is captured first: with pipefail, grep -q exiting early would fail the pipeline through SIGPIPE.
has_sync() {
  local help
  help=$("$1" sandbox --help 2> /dev/null) || return 1
  grep -qE '^[[:space:]]+sync[[:space:]]' <<< "$help"
}

if command -v tuist > /dev/null 2>&1 && has_sync tuist; then
  echo "tuist $(tuist version 2> /dev/null || echo '(unknown version)') already has tuist sandbox sync"
  exit 0
fi

case "$(uname -s)" in
  Linux) ;;
  *) echo "This script installs the Linux CLI. On macOS, install Tuist with 'mise use -g tuist@latest'." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

version="${TUIST_VERSION:-}"
if [ -z "$version" ]; then
  # CLI releases are tagged with a bare version; the repository's other components use name@version.
  version=$(curl -fsSL "https://api.github.com/repos/tuist/tuist/releases?per_page=100" \
    | grep -oE '"tag_name": *"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -z "$version" ]; then
    echo "Could not look up the newest Tuist release. Set TUIST_VERSION, for example TUIST_VERSION=4.220.0." >&2
    exit 1
  fi
fi

bin_dir="${TUIST_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$bin_dir"
url="https://github.com/tuist/tuist/releases/download/${version}/tuist-linux-${arch}.tar.gz"
echo "Installing tuist ${version} from ${url}"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
curl -fsSL "$url" -o "$scratch/tuist.tar.gz"
tar -xzf "$scratch/tuist.tar.gz" -C "$scratch" tuist
install -m 0755 "$scratch/tuist" "$bin_dir/tuist"

if ! has_sync "$bin_dir/tuist"; then
  echo "tuist ${version} has no 'tuist sandbox sync'. Install a newer release with TUIST_VERSION." >&2
  exit 1
fi
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Installed to $bin_dir/tuist. Add $bin_dir to PATH, or call it by that path." ;;
esac
echo "tuist ${version} installed"
