import Foundation
import Path
import TuistProcess

/// Mirrors a local Git worktree into a sandbox, one way, the way Amp mirrors an orb into its Mac satellite: after a sync
/// the sandbox's copy has exactly the worktree's files that Git does not ignore, tracked or not, with their content,
/// executable bits and symbolic links. Git only lists and hashes the files here; the sandbox needs neither Git nor
/// access to the repository's remote, so private repositories and unpushed work need nothing extra.
///
/// Each sync sends a tar of the files whose content or mode changed since the last sync to that path in that sandbox,
/// together with the list of every file. The sandbox deletes the files that dropped out of the list. Files it created
/// that were never in the list, such as build products, stay. The first sync to a sandbox sends every file.
struct SandboxSync {
    struct Result: Codable, Equatable {
        /// The repository's path in the sandbox.
        let root: String
        /// How many files were sent because they are new or changed.
        let changedFiles: Int
        /// The size of what was uploaded.
        let bytes: Int
        /// Whether anything was uploaded, rather than the sandbox having this worktree already.
        let uploaded: Bool

        enum CodingKeys: String, CodingKey {
            case root, bytes, uploaded
            case changedFiles = "changed_files"
        }
    }

    /// A file as Git sees it in the worktree.
    struct Entry: Equatable {
        let mode: String
        let object: String
        let path: String
    }

    /// The sandbox's copy is not the one the changes were computed against.
    private static let staleExitCode = 3
    private static let keptManifests = 20

    let remote: SandboxRemote
    let commandRunner: CommandRunning

    /// - Parameter destination: The repository's path in the sandbox. Defaults to `$HOME/work/<repository name>`.
    func sync(repository: AbsolutePath, destination: String?) async throws -> Result {
        let state = try AbsolutePath(
            validating: try await git(["rev-parse", "--path-format=absolute", "--git-path", "tuist-sync"], in: repository)
        )
        let manifests = state.appending(component: "manifests")
        try FileManager.default.createDirectory(atPath: manifests.pathString, withIntermediateDirectories: true)
        let entries = try await worktreeEntries(repository, index: state.appending(component: "index"))
        let manifest = state.appending(component: "manifest.next")
        try Self.serialize(entries).write(to: URL(fileURLWithPath: manifest.pathString))
        let id = try await git(["hash-object", "--no-filters", manifest.pathString], in: repository)

        let (root, remoteID) = try await probe(destination ?? "$HOME/work/\(repository.basename)")
        if remoteID == id {
            return Result(root: root, changedFiles: 0, bytes: 0, uploaded: false)
        }
        let previous = remoteID
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: manifests.appending(component: $0).pathString)) }
            .map(Self.entries)

        var result = try await send(
            Self.changes(from: previous, to: entries),
            of: entries,
            repository: repository,
            root: root,
            id: id,
            expecting: previous == nil ? nil : remoteID
        )
        if result == nil {
            // The sandbox's copy moved since the probe, such as through a sync from elsewhere: send everything.
            result = try await send(entries, of: entries, repository: repository, root: root, id: id, expecting: nil)
        }
        guard let result else {
            throw SandboxCommandError.stepFailed("Syncing the worktree to the sandbox", "The sandbox's copy kept changing.")
        }

        let saved = manifests.appending(component: id)
        try? FileManager.default.removeItem(atPath: saved.pathString)
        try FileManager.default.moveItem(atPath: manifest.pathString, toPath: saved.pathString)
        try Self.prune(manifests)
        return result
    }

    /// The files Git does not ignore, from a scratch index kept between syncs so unchanged files are not hashed again,
    /// and so the user's staging area is never touched. Submodules are left out.
    private func worktreeEntries(_ repository: AbsolutePath, index: AbsolutePath) async throws -> [Entry] {
        if !FileManager.default.fileExists(atPath: index.pathString) {
            // Starting from the real index reuses its cached file metadata, so the first sync hashes only changed files.
            let realIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: repository)
            try? FileManager.default.copyItem(atPath: realIndex, toPath: index.pathString)
        }
        let environment = ["GIT_INDEX_FILE": index.pathString]
        _ = try await git(["add", "-A"], in: repository, environment: environment)
        // Not trimmed like other Git output, because a path can end with whitespace.
        let listing = try await commandRunner.run(
            arguments: ["git", "-C", repository.pathString, "ls-files", "-s", "-z"],
            environment: ProcessInfo.processInfo.environment.merging(environment) { $1 }
        ).concatenatedString(including: [.standardOutput])
        return Self.entries(fromIndexListing: listing)
    }

    /// Creates `destination` in the sandbox and returns its absolute path and the ID of the worktree it holds, if any.
    private func probe(_ destination: String) async throws -> (root: String, id: String?) {
        let probed = try await remote.capture(
            #"""
            set -eu
            case "$TUIST_DEST" in '$HOME'*) root="$HOME${TUIST_DEST#'$HOME'}" ;; *) root="$TUIST_DEST" ;; esac
            mkdir -p "$root"
            root=$(cd "$root" && pwd -P)
            state="$HOME/.tuist-sync/$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
            printf 'root %s\n' "$root"
            printf 'id %s\n' "$(cat "$state/id" 2> /dev/null || true)"
            """#,
            environment: ["TUIST_DEST": destination]
        )
        let lines = probed.stdout.split(separator: "\n").map(String.init)
        guard probed.exit.exitCode == 0,
              let root = lines.last(where: { $0.hasPrefix("root ") })?.dropFirst(5),
              let id = lines.last(where: { $0.hasPrefix("id ") || $0 == "id" })
        else {
            throw SandboxCommandError.stepFailed("Preparing \(destination) in the sandbox", probed.stdout + probed.stderr)
        }
        let value = id.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return (String(root), value.isEmpty ? nil : value)
    }

    /// Uploads `changes` and the list of `entries` and applies them. Returns nil when `expecting` is set and the
    /// sandbox no longer holds that worktree.
    private func send(
        _ changes: [Entry],
        of entries: [Entry],
        repository: AbsolutePath,
        root: String,
        id: String,
        expecting: String?
    ) async throws -> Result? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tuist-sandbox-sync-\(UUID().uuidString)")
        let bundle = scratch.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let list = scratch.appendingPathComponent("changed")
        try Data(changes.map { $0.path + "\0" }.joined().utf8).write(to: list)
        try Data(entries.map { $0.path + "\0" }.joined().utf8).write(to: bundle.appendingPathComponent("paths"))
        let environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
        try await commandRunner.run(
            arguments: [
                "tar", "-czf", bundle.appendingPathComponent("files.tar.gz").path,
                "-C", repository.pathString, "--null", "-T", list.path,
            ],
            environment: environment
        ).awaitCompletion()
        let archive = scratch.appendingPathComponent("bundle.tar")
        try await commandRunner.run(
            arguments: ["tar", "-cf", archive.path, "-C", bundle.path, "files.tar.gz", "paths"],
            environment: environment
        ).awaitCompletion()
        let bytes = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0

        let remoteBundle = "/tmp/tuist-sync-\(UUID().uuidString).tar"
        try await remote.upload(archive, to: remoteBundle)
        let applied = try await remote.capture(
            #"""
            set -eu
            work=$(mktemp -d "${TMPDIR:-/tmp}/tuist-sync.XXXXXX")
            trap 'rm -rf "$work" "$TUIST_BUNDLE"' EXIT
            state="$HOME/.tuist-sync/$(printf '%s' "$TUIST_ROOT" | cksum | cut -d' ' -f1)"
            if [ -n "$TUIST_EXPECTED" ] && [ "$(cat "$state/id" 2> /dev/null || true)" != "$TUIST_EXPECTED" ]; then
              exit \#(Self.staleExitCode)
            fi
            tar -xf "$TUIST_BUNDLE" -C "$work"
            mkdir -p "$state" "$TUIST_ROOT"
            cd "$TUIST_ROOT"
            # Delete the files that dropped out of the list, and the directories that leaves empty.
            if [ -f "$state/paths" ]; then
              perl -0e '
                my %keep;
                open my $new, "<", $ARGV[1] or die "$ARGV[1]: $!";
                while (<$new>) { chomp; $keep{$_} = 1 }
                open my $old, "<", $ARGV[0] or die "$ARGV[0]: $!";
                while (<$old>) {
                  chomp;
                  next if $keep{$_};
                  unlink $_;
                  my $dir = $_;
                  while ($dir =~ s{/[^/]*\z}{} && rmdir $dir) {}
                }
              ' "$state/paths" "$work/paths"
            fi
            tar -xzf "$work/files.tar.gz"
            mv "$work/paths" "$state/paths"
            printf '%s' "$TUIST_ID" > "$state/id"
            """#,
            environment: [
                "TUIST_BUNDLE": remoteBundle,
                "TUIST_ROOT": root,
                "TUIST_ID": id,
                "TUIST_EXPECTED": expecting ?? "",
            ]
        )
        if applied.exit.exitCode == Self.staleExitCode, expecting != nil { return nil }
        guard applied.exit.exitCode == 0 else {
            throw SandboxCommandError.stepFailed("Syncing the worktree to the sandbox", applied.stdout + applied.stderr)
        }
        return Result(root: root, changedFiles: changes.count, bytes: bytes, uploaded: true)
    }

    /// The entries to send: every one when the sandbox's previous worktree is unknown, otherwise the new ones and those
    /// whose content or mode changed.
    static func changes(from previous: [Entry]?, to entries: [Entry]) -> [Entry] {
        guard let previous else { return entries }
        let known = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        return entries.filter { known[$0.path] != $0 }
    }

    /// Parses `git ls-files -s -z` output (`<mode> <object> <stage>\t<path>\0`), leaving out submodules.
    static func entries(fromIndexListing listing: String) -> [Entry] {
        listing.split(separator: "\0").compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count >= 2, fields[0] != "160000" else { return nil }
            return Entry(mode: String(fields[0]), object: String(fields[1]), path: String(record[record.index(after: tab)...]))
        }
    }

    /// The manifest saved between syncs: `<mode> <object>\t<path>\0` per entry.
    static func serialize(_ entries: [Entry]) -> Data {
        Data(entries.map { "\($0.mode) \($0.object)\t\($0.path)\0" }.joined().utf8)
    }

    static func entries(_ manifest: Data) -> [Entry] {
        entries(fromIndexListing: String(decoding: manifest, as: UTF8.self))
    }

    private static func prune(_ manifests: AbsolutePath) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: manifests.pathString)
            .map { manifests.appending(component: $0) }
        let byAge = files.sorted {
            let first = (try? FileManager.default.attributesOfItem(atPath: $0.pathString)[.modificationDate] as? Date) ??
                .distantPast
            let second = (try? FileManager.default.attributesOfItem(atPath: $1.pathString)[.modificationDate] as? Date) ??
                .distantPast
            return first > second
        }
        for file in byAge.dropFirst(keptManifests) {
            try? FileManager.default.removeItem(atPath: file.pathString)
        }
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
}
