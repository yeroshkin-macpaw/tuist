import ArgumentParser
import TuistNooraExtension

public struct SandboxRunCommand: AsyncParsableCommand, NooraReadyCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a shell command in a sandbox, streaming its output however long it runs.",
        discussion: """
        The command starts detached in the sandbox, so it outlives dropped connections: the output stream reconnects \
        where it stopped. On a macOS sandbox whose host CI is using, it waits for the host for up to 15 minutes. \
        Interrupting cancels the command. Exits with the command's status, or 124 when it times out.
        """
    )

    @OptionGroup var sandbox: SandboxID
    @OptionGroup var options: SandboxOptions

    @Option(name: .long, help: "Working directory in the sandbox. Defaults to the sandbox's workspace.")
    var cwd: String?

    @Option(name: .long, parsing: .singleValue, help: "An environment variable as NAME=VALUE. Repeatable. Never stored.")
    var env: [String] = []

    @Option(name: .long, help: "Kill the command after this many seconds (1–21600). Defaults to one hour.")
    var timeout: Int?

    @Argument(parsing: .postTerminator, help: "The command to run, after `--`.")
    var command: [String] = []

    public var jsonThroughNoora: Bool { true }

    var environment: [String: String] {
        Dictionary(env.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }, uniquingKeysWith: { $1 })
    }

    public func validate() throws {
        guard !command.isEmpty else { throw ValidationError("Pass the command to run after `--`.") }
        if let timeout, !(1 ... 21600).contains(timeout) { throw ValidationError("Timeout must be 1–21600 seconds.") }
        if let invalid = env.first(where: { !$0.contains("=") || $0.hasPrefix("=") }) {
            throw ValidationError("Pass environment variables as NAME=VALUE, not \(invalid).")
        }
    }

    public func run() async throws {
        try await SandboxCommandService().run(
            options: options.values,
            sandboxID: sandbox.sandboxID,
            command: command.joined(separator: " "),
            cwd: cwd,
            environment: environment,
            timeoutMs: timeout.map { $0 * 1000 }
        )
    }
}
