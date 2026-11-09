---
name: remote-mac
description: Builds, tests and runs Apple-platform code (Xcode, xcodebuild, Swift for iOS or macOS, the iOS Simulator) on a remote Tuist macOS sandbox when the current machine is not a Mac, such as a Linux container or cloud agent sandbox. Use when a task needs xcodebuild, simulators, screenshots of an iOS app or other macOS-only tools and `uname` is not Darwin.
hooks:
  SessionEnd:
    - hooks:
        - type: command
          command: 'f="${XDG_STATE_HOME:-$HOME/.local/state}/tuist-remote-mac/$(sed -n ''s/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p'' | head -n 1).sh"; if [ -f "$f" ]; then s=$(command -v setsid || true); nohup $s bash "$f" > /dev/null 2>&1 & fi'
---

# Remote Mac

A Tuist macOS sandbox is a Mac with Xcode and iOS simulators that you drive from here with the `tuist sandbox` commands. You keep editing files locally; before each command you mirror the local Git worktree into the Mac, then run the command there and read its output here.

The scripts below are in this skill's `scripts` directory (`${CLAUDE_SKILL_DIR}/scripts` in Claude Code).

## Setup

1. Run `${CLAUDE_SKILL_DIR}/scripts/install-tuist.sh`. It does nothing when the `tuist` on PATH has `tuist sandbox sync`; otherwise it installs the newest Linux CLI into `~/.local/bin` (`TUIST_VERSION` picks a release). If `~/.local/bin` is not on PATH, prepend it: `export PATH="$HOME/.local/bin:$PATH"`.
2. Authenticate with one of:
   - `TUIST_TOKEN` set to an account token with the `account:sandboxes:use` scope (created in the account's token settings). Prefer this in non-interactive environments. In a Claude Code cloud environment, the user sets it in the environment's variables.
   - `tuist auth login`, which needs a browser; ask the user to run it.
3. Pick the account. The Linux CLI does not read `Tuist.swift`, so pass `--account <handle>` to every `tuist sandbox` command unless the repository has a `tuist.toml` with `project = "<account>/<project>"`. Most examples below leave it out.
4. Check access with `tuist sandbox list --account <handle>`. If the request cannot reach `tuist.dev` (a connection error, or a 403 from a proxy rather than from Tuist), the sandbox restricts network access: ask the user to allow `tuist.dev`. In a Claude Code cloud environment, that is **Custom** network access with `tuist.dev` in **Allowed domains** and the default domains kept.

## Workflow

Create one Mac per task and reuse it, so builds stay incremental:

```bash
${CLAUDE_SKILL_DIR}/scripts/create-mac.sh "${CLAUDE_SESSION_ID}" --account <handle>   # note the "id"
```

The script passes its options to `tuist sandbox create --platform macos --json`. In Claude Code, it also records the Mac so it is deleted when the session ends. Elsewhere the session ID is empty and nothing is recorded.

Before every command, mirror the worktree. Sync is one-way: edit files locally, not on the Mac, because the next sync overwrites the Mac's copies of tracked files. Unpushed commits and uncommitted changes are included, and private repositories work.

```bash
tuist sandbox sync <id> --json                 # "root" is the repository's path on the Mac
```

Run commands from that root. `exec` streams the output however long the command takes, waits when the Mac's host is busy with CI, and exits with the command's status:

```bash
tuist sandbox exec <id> --cwd <root> -- 'xcodebuild -scheme App -destination "platform=iOS Simulator,name=iPhone 17 Pro" build'
tuist sandbox exec <id> --cwd <root> -- 'xcrun simctl list devices available'
```

- Pipe long build output through `tail` or `xcbeautify` on the Mac to keep it short.
- Pass secrets with `--env NAME=VALUE`; they are never stored.
- `--timeout <seconds>` defaults to one hour. Exit code 124 means the command timed out.

Copy results back with `cp`, writing the Mac's side as `<id>:<path>`, such as a built app, an `.xcresult` bundle or a screenshot:

```bash
tuist sandbox exec <id> --cwd <root> -- 'xcrun simctl io booted screenshot /tmp/screen.png'
tuist sandbox cp <id>:/tmp/screen.png .tuist-mac/
```

Then read `.tuist-mac/screen.png` to look at it. Add the output directory to `.gitignore` or remove it afterwards so it is not mirrored back.

When the task is done, delete the Mac so it does not hold capacity:

```bash
tuist sandbox delete <id> --yes --account <handle>
```

If a Mac is left behind, Tuist pauses it when it is idle and deletes it after 14 days paused.

## Long commands

The first sync of a large repository, builds and test runs can take longer than a shell tool waits. Stopping `tuist sandbox exec` locally (Ctrl-C, SIGTERM, or a tool timeout that kills it) cancels the command on the Mac, so start long commands in the background and read their output while they run:

- In Claude Code, run them with the Bash tool's `run_in_background` and check the output as it progresses. A foreground command that reaches the Bash timeout moves to the background and is stopped 30 minutes later, so do not start one that may need longer in the foreground. For longer builds, the user can raise `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS` in the environment.
- Elsewhere, redirect to a log file, such as `tuist sandbox exec <id> --cwd <root> -- '…' > /tmp/build.log 2>&1 &`, then read the log until the process exits. Its exit status is the command's.

## Simulator tips

- Boot a device before installing: `xcrun simctl boot "iPhone 17 Pro" || true`.
- Build into a known directory with `-derivedDataPath DerivedData`, then `xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/<App>.app` and `xcrun simctl launch booted <bundle id>`.
- `DerivedData` inside the repository is fine when Git ignores it: sync keeps ignored files on the Mac.
