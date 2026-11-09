#!/usr/bin/env bash
# Creates a Tuist macOS sandbox and prints `tuist sandbox create --json`.
#
#   create-mac.sh <session-id> [tuist sandbox create options, such as --account my-org]
#
# With a session ID, it also records how to delete the Mac in
# ${XDG_STATE_HOME:-~/.local/state}/tuist-remote-mac/<session-id>.sh, which the skill's
# SessionEnd hook runs when that Claude Code session ends. Pass an empty session ID to
# record nothing; then delete the Mac yourself.
set -euo pipefail

session="${1-}"
shift || true

tuist=$(command -v tuist || true)
if [ -z "$tuist" ]; then
  echo "tuist is not on PATH. Run install-tuist.sh first." >&2
  exit 1
fi

output=$("$tuist" sandbox create --platform macos --json "$@")
printf '%s\n' "$output"

if [[ ! "$session" =~ ^[A-Za-z0-9_-]+$ ]]; then
  exit 0
fi
id=$(grep -oE '"id" *: *"[0-9A-Fa-f-]{36}"' <<< "$output" | head -n 1 | grep -oE '[0-9A-Fa-f-]{36}' || true)
if [ -z "$id" ]; then
  echo "Could not read the sandbox ID, so it is not deleted when the session ends." >&2
  exit 0
fi

# Delete with the same account and project directory the Mac was created with.
scope=()
while [ $# -gt 0 ]; do
  case "$1" in
    --account | --path | -p) [ $# -gt 1 ] && scope+=("$1" "$2") && shift ;;
    --account=* | --path=*) scope+=("$1") ;;
  esac
  shift
done

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tuist-remote-mac"
mkdir -p "$state_dir"
cleanup="$state_dir/$session.sh"
if [ ! -f "$cleanup" ]; then
  cat > "$cleanup" << 'EOF'
#!/usr/bin/env bash
# Deletes the Tuist Macs a Claude Code session created. The remote-mac skill's SessionEnd hook runs it.
trap 'rm -f -- "$0"' EXIT
EOF
fi
printf 'cd %q && %q sandbox delete %q --yes' "$PWD" "$tuist" "$id" >> "$cleanup"
[ ${#scope[@]} -eq 0 ] || printf ' %q' "${scope[@]}" >> "$cleanup"
printf '\n' >> "$cleanup"
