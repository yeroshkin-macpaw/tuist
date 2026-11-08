import Foundation
import Path
import TuistProcess

/// Mirrors a local Git worktree into a sandbox, one way: after a sync the sandbox's copy has exactly the local
/// worktree's content, including commits not pushed yet, uncommitted edits and new files that Git does not ignore.
///
/// The sandbox keeps a checkout of the base commit, the newest commit of HEAD the remote has (through the branch's
/// upstream, else `origin/HEAD`). It fetches that commit anonymously, which is fast for public repositories, and
/// otherwise receives it as a `git archive`, so private repositories need no credentials in the sandbox. Every sync
/// then uploads a binary patch from the base to the worktree, unless the sandbox has it already, and moves the
/// sandbox's worktree with a two-tree `read-tree -m -u`, which rewrites only files whose content differs, so
/// incremental builds keep the rest. Files the sandbox created that Git ignores, such as build products, stay.
struct SandboxSync {
    struct Result: Codable, Equatable {
        /// The repository's path in the sandbox.
        let root: String
        let base: String
        let patchBytes: Int
        /// Whether the patch had to be uploaded, rather than the sandbox having it already.
        let uploaded: Bool

        enum CodingKeys: String, CodingKey {
            case root, base, uploaded
            case patchBytes = "patch_bytes"
        }
    }

    private static let missingPatchExitCode = 3

    let remote: SandboxRemote
    let commandRunner: CommandRunning

    /// - Parameter destination: The repository's path in the sandbox. Defaults to `$HOME/work/<repository name>`.
    func sync(repository: AbsolutePath, destination: String?) async throws -> Result {
        let base = try await baseCommit(repository)
        let root = try await prepare(
            repository: repository,
            base: base,
            destination: destination ?? "$HOME/work/\(repository.basename)"
        )

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tuist-sandbox-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patch = scratch.appendingPathComponent("worktree.patch")
        try await worktreePatch(repository: repository, base: base, scratch: scratch, output: patch)
        let patchBytes = try FileManager.default.attributesOfItem(atPath: patch.path)[.size] as? Int ?? 0
        let id = try await git(["hash-object", patch.path], in: repository)
        let remotePatch = "\(root)/.git/tuist-sync/\(id).patch"

        var uploaded = false
        var applied = try await apply(root: root, base: base, patch: remotePatch)
        if applied.exit.exitCode == Self.missingPatchExitCode {
            try await remote.upload(patch, to: remotePatch)
            uploaded = true
            applied = try await apply(root: root, base: base, patch: remotePatch)
        }
        guard applied.exit.exitCode == 0 else {
            throw SandboxCommandError.stepFailed("Syncing the worktree to the sandbox", applied.stdout + applied.stderr)
        }
        return Result(root: root, base: base, patchBytes: patchBytes, uploaded: uploaded)
    }

    func baseCommit(_ repository: AbsolutePath) async throws -> String {
        for upstream in ["@{upstream}", "refs/remotes/origin/HEAD"] {
            if let base = try? await git(["merge-base", "HEAD", upstream], in: repository) { return base }
        }
        return try await git(["rev-parse", "HEAD"], in: repository)
    }

    /// Makes sure the sandbox has a repository at `destination` with the base commit under `refs/tuist/bases/<base>`
    /// and a worktree checked out, and returns the repository's absolute path there.
    private func prepare(repository: AbsolutePath, base: String, destination: String) async throws -> String {
        let origin = (try? await git(["config", "--get", "remote.origin.url"], in: repository)).map(Self.anonymousURL)
        let script = """
        set -eu
        root=\(destination.hasPrefix("$HOME") ? "\"$HOME\"\(Self.quoted(String(destination.dropFirst(5))))" : Self
            .quoted(destination))
        mkdir -p "$root"
        cd "$root"
        root=$(pwd -P)
        [ -d .git ] || git init -q
        if ! git rev-parse -q --verify "refs/tuist/bases/$TUIST_BASE^{commit}" > /dev/null; then
          if [ -n "${TUIST_ORIGIN:-}" ] && GIT_TERMINAL_PROMPT=0 git -c protocol.version=2 -c credential.helper= \\
              fetch -q --depth 1 --no-tags "$TUIST_ORIGIN" "$TUIST_BASE" 2> /dev/null; then
            git update-ref "refs/tuist/bases/$TUIST_BASE" "$TUIST_BASE"
          else
            echo "missing $root"
            exit 0
          fi
        fi
        git rev-parse -q --verify HEAD > /dev/null || git checkout -q --detach "refs/tuist/bases/$TUIST_BASE"
        echo "ready $root"
        """
        var environment = ["TUIST_BASE": base]
        environment["TUIST_ORIGIN"] = origin
        var prepared = try await remote.capture(script, environment: environment)
        if prepared.exit.exitCode == 0, let root = Self.preparedRoot(prepared.stdout, state: "missing") {
            try await uploadArchive(repository: repository, base: base, root: root)
            prepared = try await remote.capture(script, environment: ["TUIST_BASE": base])
        }
        guard prepared.exit.exitCode == 0, let root = Self.preparedRoot(prepared.stdout, state: "ready") else {
            throw SandboxCommandError.stepFailed("Preparing the repository in the sandbox", prepared.stdout + prepared.stderr)
        }
        return root
    }

    /// Sends the base commit's tree as a `git archive` and records it as a commit of the same tree, for repositories
    /// the sandbox cannot fetch anonymously. The commit's ID differs from the local one; only its tree matters.
    private func uploadArchive(repository: AbsolutePath, base: String, root: String) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tuist-sandbox-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("base.tar.gz")
        _ = try await git(["archive", "--format=tar.gz", "-o", archive.path, base], in: repository)
        let remoteArchive = "\(root)/.git/tuist-sync/\(base).tar.gz"
        try await remote.upload(archive, to: remoteArchive)
        let script = """
        set -eu
        cd "$TUIST_ROOT"
        tree_dir=$(mktemp -d)
        trap 'rm -rf "$tree_dir"' EXIT
        tar -xzf "$TUIST_ARCHIVE" -C "$tree_dir"
        export GIT_INDEX_FILE="$tree_dir.index"
        git --work-tree="$tree_dir" add -A -f
        commit=$(git commit-tree "$(git write-tree)" -m "Tuist sync base $TUIST_BASE")
        rm -f "$GIT_INDEX_FILE" "$TUIST_ARCHIVE"
        git update-ref "refs/tuist/bases/$TUIST_BASE" "$commit"
        """
        let result = try await remote.capture(
            script,
            environment: ["TUIST_ROOT": root, "TUIST_ARCHIVE": remoteArchive, "TUIST_BASE": base]
        )
        guard result.exit.exitCode == 0 else {
            throw SandboxCommandError.stepFailed("Unpacking the repository in the sandbox", result.stdout + result.stderr)
        }
    }

    /// The worktree's difference from `base`, tracked changes and untracked files Git does not ignore, as a binary
    /// patch. A scratch index leaves the user's staging area untouched.
    private func worktreePatch(repository: AbsolutePath, base: String, scratch: URL, output: URL) async throws {
        let index = scratch.appendingPathComponent("index")
        let realIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: repository)
        let environment = ["GIT_INDEX_FILE": index.path]
        if (try? FileManager.default.copyItem(atPath: realIndex, toPath: index.path)) == nil {
            _ = try await git(["read-tree", base], in: repository, environment: environment)
        }
        _ = try await git(["add", "-A"], in: repository, environment: environment)
        _ = try await git(
            ["diff", "--cached", "--binary", "--no-color", "--no-ext-diff", "--output=\(output.path)", base],
            in: repository,
            environment: environment
        )
    }

    /// Exits with `missingPatchExitCode` when the sandbox does not have the patch yet.
    private func apply(root: String, base: String, patch: String) async throws -> SandboxRemote.Captured {
        try await remote.capture(
            """
            set -eu
            cd "$TUIST_ROOT"
            [ -f "$TUIST_PATCH" ] || exit \(Self.missingPatchExitCode)
            export GIT_INDEX_FILE=.git/tuist-sync/target.index
            rm -f "$GIT_INDEX_FILE"
            git read-tree "refs/tuist/bases/$TUIST_BASE"
            if [ -s "$TUIST_PATCH" ]; then git apply --cached --binary --whitespace=nowarn "$TUIST_PATCH"; fi
            target=$(git write-tree)
            unset GIT_INDEX_FILE
            git add -A
            current=$(git write-tree)
            git read-tree -m -u "$current" "$target"
            git reset -q
            find .git/tuist-sync -name '*.patch' ! -path "$TUIST_PATCH" -mmin +60 -delete 2> /dev/null || true
            """,
            environment: ["TUIST_ROOT": root, "TUIST_BASE": base, "TUIST_PATCH": patch]
        )
    }

    private func git(_ arguments: [String], in repository: AbsolutePath, environment: [String: String] = [:]) async throws
        -> String
    {
        try await commandRunner.run(
            arguments: ["git", "-C", repository.pathString] + arguments,
            environment: ProcessInfo.processInfo.environment.merging(environment) { $1 }
        )
        .concatenatedString(including: [.standardOutput])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preparedRoot(_ output: String, state: String) -> String? {
        output.split(separator: "\n").lazy
            .compactMap { line in line.hasPrefix("\(state) ") ? String(line.dropFirst(state.count + 1)) : nil }
            .last
    }

    /// GitHub over SSH becomes HTTPS, which needs no key for a public repository.
    static func anonymousURL(_ url: String) -> String {
        guard let match = url.firstMatch(of: #/github\.com[/:]([^/]+)/(.+?)(?:\.git)?$/#) else { return url }
        return "https://github.com/\(match.1)/\(match.2).git"
    }

    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: #"'\''"#))'"
    }
}
