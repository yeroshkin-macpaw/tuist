---
name: remote-mac
description: Builds, tests and runs Apple-platform code (Xcode, xcodebuild, Swift for iOS or macOS, the iOS Simulator) on a remote Tuist macOS sandbox when the current machine is not a Mac, such as a Linux container or cloud agent sandbox. Use when a task needs xcodebuild, simulators, screenshots of an iOS app or other macOS-only tools and `uname` is not Darwin.
---

# Remote Mac

A Tuist macOS sandbox is a Mac with Xcode and iOS simulators that you drive from here with the `tuist sandbox` commands. You keep editing files locally; before each command you mirror the local Git worktree into the Mac, then run the command there and read its output here.

## Setup

1. Check that `tuist sandbox run --help` works. If the command is missing, the Tuist CLI is too old; install the latest with `mise use -g tuist@latest`, or ask the user to.
2. Authenticate with one of:
   - `TUIST_TOKEN` set to an account token with the `account:sandboxes:use` scope (created in the account's token settings). Prefer this in non-interactive environments.
   - `tuist auth login`, which needs a browser; ask the user to run it.
3. The account comes from the project's `Tuist.swift` `fullHandle`. Pass `--account <handle>` to every command when the project has none.

## Workflow

Create one Mac per task and reuse it, so builds stay incremental:

```bash
tuist sandbox create --platform macos --json   # note the "id"
```

Before every command, mirror the worktree. Sync is one-way: edit files locally, not on the Mac, because the next sync overwrites the Mac's copies of tracked files. Unpushed commits and uncommitted changes are included, and private repositories work.

```bash
tuist sandbox sync <id> --json                 # "root" is the repository's path on the Mac
```

Run commands from that root. `run` streams the output however long the command takes, waits when the Mac's host is busy with CI, and exits with the command's status:

```bash
tuist sandbox run <id> --cwd <root> -- 'xcodebuild -scheme App -destination "platform=iOS Simulator,name=iPhone 17 Pro" build'
tuist sandbox run <id> --cwd <root> -- 'xcrun simctl list devices available'
```

- Pipe long build output through `tail` or `xcbeautify` on the Mac to keep it short, and run long builds in the background if your harness supports it.
- Pass secrets with `--env NAME=VALUE`; they are never stored.
- `--timeout <seconds>` defaults to one hour. Exit code 124 means the command timed out.

Copy results back with `download`, such as a built app, an `.xcresult` bundle or a screenshot:

```bash
tuist sandbox run <id> --cwd <root> -- 'xcrun simctl io booted screenshot /tmp/screen.png'
tuist sandbox download <id> /tmp/screen.png -o .tuist-mac
```

Then read `.tuist-mac/screen.png` to look at it. Add the output directory to `.gitignore` or remove it afterwards so it is not mirrored back.

When the task is done, delete the Mac so it does not hold capacity:

```bash
tuist sandbox delete <id> --yes
```

## Simulator tips

- Boot a device before installing: `xcrun simctl boot "iPhone 17 Pro" || true`.
- Build into a known directory with `-derivedDataPath DerivedData`, then `xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/<App>.app` and `xcrun simctl launch booted <bundle id>`.
- `DerivedData` inside the repository is fine when Git ignores it: sync keeps ignored files on the Mac.
