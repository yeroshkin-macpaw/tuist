import Testing
@testable import TuistSandboxCommand

struct SandboxSyncTests {
    @Test
    func entries_parseTheIndexListingAndSkipSubmodules() {
        let listing = [
            "100644 aaaa 0\tname with\ttab ",
            "160000 bbbb 0\tVendor/Submodule",
            "120000 cccc 0\tlink",
        ].map { $0 + "\0" }.joined()

        let entries = SandboxSync.entries(fromIndexListing: listing)

        #expect(entries == [
            SandboxSync.Entry(mode: "100644", object: "aaaa", path: "name with\ttab "),
            SandboxSync.Entry(mode: "120000", object: "cccc", path: "link"),
        ])
        #expect(SandboxSync.entries(SandboxSync.serialize(entries)) == entries)
    }

    @Test
    func changes_sendNewFilesAndThoseWhoseContentOrModeChanged() {
        let previous = [
            SandboxSync.Entry(mode: "100644", object: "1111", path: "same"),
            SandboxSync.Entry(mode: "100644", object: "2222", path: "edited"),
            SandboxSync.Entry(mode: "100644", object: "3333", path: "made-executable"),
            SandboxSync.Entry(mode: "100644", object: "4444", path: "deleted"),
        ]
        let current = [
            SandboxSync.Entry(mode: "100644", object: "1111", path: "same"),
            SandboxSync.Entry(mode: "100644", object: "2223", path: "edited"),
            SandboxSync.Entry(mode: "100755", object: "3333", path: "made-executable"),
            SandboxSync.Entry(mode: "100644", object: "5555", path: "added"),
        ]

        #expect(SandboxSync.changes(from: previous, to: current).map(\.path) == ["edited", "made-executable", "added"])
        #expect(SandboxSync.changes(from: nil, to: current) == current)
    }
}
