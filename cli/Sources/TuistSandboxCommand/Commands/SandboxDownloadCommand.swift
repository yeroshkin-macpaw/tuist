import ArgumentParser
import TuistNooraExtension

public struct SandboxDownloadCommand: AsyncParsableCommand, NooraReadyCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Copy a file or directory out of a sandbox, such as a built .app, an .xcresult bundle or a screenshot."
    )

    @OptionGroup var sandbox: SandboxID
    @OptionGroup var options: SandboxOptions

    @Argument(help: "The path in the sandbox.")
    var remotePath: String

    @Option(
        name: .shortAndLong,
        help: "Local directory to copy it into. Defaults to the working directory.",
        completion: .directory
    )
    var output: String?

    public var jsonThroughNoora: Bool { true }

    public func run() async throws {
        try await SandboxCommandService().download(
            options: options.values,
            sandboxID: sandbox.sandboxID,
            remotePath: remotePath,
            outputDirectory: output
        )
    }
}
