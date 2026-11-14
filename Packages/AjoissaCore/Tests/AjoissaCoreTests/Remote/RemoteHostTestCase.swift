import AjoissaCore
import XCTest

/// A "remote" machine that is this Mac, reached through a real shell reading the real scripts: everything
/// but the network. The scripts run against a folder made for the test.
class RemoteHostTestCase: XCTestCase {
    /// The shells every script must work in: bash in POSIX mode, as on a Mac, and dash, as on Debian.
    static let shells = ["/bin/sh", "/bin/dash"]

    var root: URL!

    override func setUpWithError() throws {
        // The folder is given with its links followed, so paths the shell reports match the ones asked for.
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "ajoissa-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may have locked a folder; unlock everything so it can be removed.
        if let paths = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in paths {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try FileManager.default.removeItem(at: root)
    }

    func shell(_ path: String) -> RemoteShell {
        RemoteShell(runner: ProcessCommandRunner(), executable: path, arguments: [])
    }

    /// The machine as seen through `shell`, with its home folder set to the test's folder.
    func host(_ shellPath: String, launchctl: String = "/bin/launchctl") throws -> RemoteHost {
        var facts = try RemoteHost.probe(shell(shellPath))
        facts.home = root.path
        return RemoteHost(name: "studio", shell: shell(shellPath), facts: facts, launchctlPath: launchctl)
    }

    /// Runs `body` once for each shell. `host.shellName` in a message says which one failed.
    func inEveryShell(_ body: (RemoteHost) throws -> Void) throws {
        for shellPath in Self.shells {
            do {
                try body(try host(shellPath))
            } catch {
                XCTFail("\(shellPath): \(error)")
            }
        }
    }

    @discardableResult
    func write(_ name: String, _ contents: String = "x", modified: Date? = nil) throws -> String {
        try write(name, data: Data(contents.utf8), modified: modified)
    }

    @discardableResult
    func write(_ name: String, data: Data, modified: Date? = nil) throws -> String {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url.path
    }

    func lock(_ name: String, permissions: Int = 0o000) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.appending(path: name).path)
    }
}
