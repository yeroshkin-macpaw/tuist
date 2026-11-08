import ArgumentParser
import TuistNooraExtension

public struct SandboxSyncCommand: AsyncParsableCommand, NooraReadyCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Mirror the local Git worktree into a sandbox, including unpushed commits and uncommitted changes.",
        discussion: """
        One way: the sandbox's copy ends up with exactly the worktree's content, and files there that the repository \
        tracks are overwritten. Files the sandbox created that Git ignores, such as build products, stay, so builds \
        there stay incremental. Repositories the sandbox cannot fetch anonymously are uploaded, so private ones work \
        too. Pass --path to sync another directory's repository.
        """
    )

    @OptionGroup var sandbox: SandboxID
    @OptionGroup var options: SandboxOptions

    @Option(name: .long, help: "The repository's path in the sandbox. Defaults to $HOME/work/<repository name>.")
    var to: String?

    public var jsonThroughNoora: Bool { true }

    public func run() async throws {
        try await SandboxCommandService().sync(options: options.values, sandboxID: sandbox.sandboxID, destination: to)
    }
}
