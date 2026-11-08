# Sandbox commands

`tuist sandbox` manages an account's sandboxes through the sandbox API.

- Keep list, show, analytics, pause, resume, archive and delete aligned with the
  public API and MCP contract in `server/lib/tuist/sandboxes/query.ex` and
  `schemas.ex`; create and exec use the API only (MCP omits them). Change server
  schemas and regenerate OpenAPI; never edit generated files.
- The server enforces roles (members reach their own build sandboxes, admins
  everything); the CLI does not check them. `--account` overrides the project
  full-handle account.
- `exec` joins the arguments after `--` with spaces and the server runs them with
  `/bin/bash -lc`; it prints the streams and exits with the command's exit status
  (`ExitCode`), without an error message. Pausing a sandbox that is already paused
  succeeds. Deleting requires `--yes`.
- An error status whose body is not the server's `{"message": …}`, such as a
  proxy's error page, reports the status, not the generated client's decoding error.
- Show the dashboard `status` and fall back to `state` for servers that do not
  send it. `status` and `bucket` are open strings: never switch on them exhaustively.
- Test through the generated Xcode workspace and Swift Testing, not SwiftPM.
- `run`, `sync` and `download` go through the commands API (`SandboxRemote`):
  a command starts detached and its ND-JSON log stream resumes from the last
  byte offsets after a drop, a 5xx or a mid-stream `error` line, giving up after
  15 minutes without progress; a 404 ends it at once. Starting a command and
  stdin writes wait through 503s while CI holds a shared macOS host. `run` exits
  with the command's status (124 on timeout, 130 when cancelled) and cancels it
  on SIGINT/SIGTERM. Progress notes go to stderr, never stdout.
- `sync` (`SandboxSync`) mirrors the Git worktree one way: the sandbox keeps the
  base commit (merge-base with the upstream, else `origin/HEAD`) under
  `refs/tuist/bases/<sha>`, fetched anonymously or uploaded as a `git archive`
  for private repositories, then applies a binary patch with a two-tree
  `read-tree -m -u` so unchanged files and ignored build outputs stay. A patch
  the sandbox already has is not uploaded again. A scratch index keeps the
  user's staging area untouched.
