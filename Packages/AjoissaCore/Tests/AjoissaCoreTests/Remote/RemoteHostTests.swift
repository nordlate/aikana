@testable import AjoissaCore
import XCTest

final class RemoteHostTests: RemoteHostTestCase {
    private let time = Date(timeIntervalSince1970: 1_763_085_600)

    // MARK: - Files by pattern

    func testFilesMatchingAPattern() throws {
        try write("reports/a.md", "12345", modified: time)
        try write("reports/b.md", "1", modified: time.addingTimeInterval(60))
        try write("reports/c.txt")
        try inEveryShell { host in
            let files = try host.files(matching: "\(root.path)/reports/*.md")
            XCTAssertEqual(files.map(\.path), ["\(root.path)/reports/a.md", "\(root.path)/reports/b.md"])
            XCTAssertEqual(files.map(\.size), [5, 1])
            XCTAssertEqual(files.map(\.modified), [time, time.addingTimeInterval(60)])
            XCTAssertNotNil(files.first?.identity)
            XCTAssertNotEqual(files.first?.identity, files.last?.identity)
        }
    }

    func testTildeIsTheHomeFolderOnTheMachine() throws {
        try write("out/x.dat")
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "~/out/*.dat").map(\.path), ["\(root.path)/out/x.dat"])
            XCTAssertEqual(try host.file(at: "~/out/x.dat")?.path, "\(root.path)/out/x.dat")
        }
    }

    func testTheSameAnswerAsThisMacGives() throws {
        try write("logs/one.log", "abc", modified: time)
        try write("logs/two.log", "", modified: time)
        let local = LocalHost(homeDirectory: root, runner: ProcessCommandRunner())
        try inEveryShell { host in
            for pattern in ["~/logs/*.log", "~/logs/one.log", "~/logs/none.log", "~/logs/t?o.log", "~/nothing/*.log"] {
                XCTAssertEqual(try host.files(matching: pattern), try local.files(matching: pattern), pattern)
            }
            XCTAssertEqual(try host.file(at: "~/logs/one.log"), try local.file(at: "~/logs/one.log"))
            XCTAssertEqual(try host.file(at: "~/logs/none.log"), try local.file(at: "~/logs/none.log"))
        }
    }

    func testNamesAShellWouldReadSomethingIntoAreJustNames() throws {
        let names = ["with space.md", "it's.md", "$(touch pwned).md", "`touch pwned`.md", "semi;colon.md", "quote\".md", "dollar$HOME.md", "-dash.md"]
        for name in names {
            try write("odd/\(name)")
        }
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "\(root.path)/odd/*.md").map(\.path).sorted(), names.map { "\(root.path)/odd/\($0)" }.sorted())
            for name in names {
                XCTAssertEqual(try host.files(matching: "\(root.path)/odd/\(name)").count, 1, name)
                XCTAssertEqual(try host.file(at: "\(root.path)/odd/\(name)")?.size, 1, name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "pwned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "pwned"))
    }

    func testAFolderWithSpacesAndQuotesInItsName() throws {
        try write("it's a folder/x.md")
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "\(root.path)/it's a folder/*.md").count, 1)
        }
    }

    func testNothingMatchingIsAnEmptyListNotAnError() throws {
        try write("reports/a.txt")
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "\(root.path)/reports/*.md"), [])
            XCTAssertEqual(try host.files(matching: "\(root.path)/nowhere/*.md"), [])
            XCTAssertEqual(try host.files(matching: "\(root.path)/reports/missing.md"), [])
        }
    }

    func testFoldersAndOtherThingsAreNotFiles() throws {
        try write("things/file.md")
        try FileManager.default.createDirectory(at: root.appending(path: "things/folder.md"), withIntermediateDirectories: true)
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "\(root.path)/things/*.md").map(\.path), ["\(root.path)/things/file.md"])
            XCTAssertNil(try host.file(at: "\(root.path)/things/folder.md"))
        }
    }

    func testALinkIsSeenAsTheFileItPointsAt() throws {
        let target = try write("real/run.log", "twelve bytes", modified: time)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link.log").path, withDestinationPath: target)
        try inEveryShell { host in
            let file = try XCTUnwrap(try host.file(at: "\(root.path)/link.log"))
            XCTAssertEqual(file.size, 12)
            XCTAssertEqual(file.modified, time)
            XCTAssertEqual(file.identity, try host.file(at: target)?.identity)
        }
    }

    func testAFolderThatCannotBeReadIsNotTakenForNoFiles() throws {
        try write("locked/a.md")
        try lock("locked")
        try inEveryShell { host in
            XCTAssertThrowsError(try host.files(matching: "\(root.path)/locked/*.md")) { error in
                XCTAssertEqual((error as? HostAccessError)?.message, "\(root.path)/locked/*.md could not be searched: a folder on the way could not be read")
            }
            XCTAssertThrowsError(try host.files(matching: "\(root.path)/locked/a.md")) { error in
                XCTAssertEqual((error as? HostAccessError)?.message, "\(root.path)/locked/a.md could not be searched: a folder on the way could not be read")
            }
            XCTAssertThrowsError(try host.file(at: "\(root.path)/locked/a.md")) { error in
                XCTAssertEqual((error as? HostAccessError)?.message, "\(root.path)/locked/a.md could not be read: a folder on the way could not be read")
            }
        }
    }

    func testAFolderThatCanBeEnteredButNotListedHidesOnlyPatterns() throws {
        try write("dropbox/a.md")
        try lock("dropbox", permissions: 0o311)
        try inEveryShell { host in
            XCTAssertEqual(try host.files(matching: "\(root.path)/dropbox/a.md").count, 1)
            XCTAssertEqual(try host.files(matching: "\(root.path)/dropbox/missing.md"), [])
            XCTAssertThrowsError(try host.files(matching: "\(root.path)/dropbox/*.md"))
        }
    }

    func testMoreMatchesThanTheLimitAreRefused() throws {
        for index in 1...4 {
            try write("many/\(index).md")
        }
        let script = RemoteCommands.files(matching: "\(root.path)/many/*.md", in: nil, folders: [], limit: 3, stat: .bsd)
        for shellPath in Self.shells {
            XCTAssertEqual(try shell(shellPath).run(script, timeout: 5).status, "toomany", shellPath)
        }
    }

    func testAPathThatIsNotAPatternIsTakenLiterally() throws {
        try write("lit/[a].md", "exact")
        try write("lit/a.md", "pattern")
        try inEveryShell { host in
            XCTAssertEqual(try host.file(at: "\(root.path)/lit/[a].md")?.size, 5)
            XCTAssertEqual(try host.files(matching: "\(root.path)/lit/[a].md").map(\.size), [7])
        }
    }

    func testAHomeFolderWithPatternCharactersInItsNameIsNotReadAsAPattern() throws {
        let oddHome = "ho'me $(touch pwned) [a]*"
        try write("\(oddHome)/logs/run.log", "12345")
        try write("\(oddHome)/logs/-dash.log", "1")
        for shellPath in Self.shells {
            var facts = try RemoteHost.probe(shell(shellPath))
            facts.home = root.appending(path: oddHome).path
            let host = RemoteHost(name: "studio", shell: shell(shellPath), facts: facts)

            XCTAssertEqual(try host.files(matching: "~/logs/*.log").map(\.path), ["\(facts.home)/logs/-dash.log", "\(facts.home)/logs/run.log"], shellPath)
            XCTAssertEqual(try host.files(matching: "~/logs/run.log").map(\.size), [5], shellPath)
            XCTAssertEqual(try host.file(at: "~/logs/run.log")?.size, 5, shellPath)
            XCTAssertEqual(try host.read("~/logs/run.log", range: 0..<3), Data("123".utf8), shellPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "pwned"))
    }

    func testAFileThatCannotBeDescribedIsNotTakenForNoFile() throws {
        try write("out/a.md")
        // The wrong kind of `stat` for this machine: it is there, and does not understand what it is asked.
        var facts = try RemoteHost.probe(shell("/bin/sh"))
        facts.system = "Linux"
        let host = RemoteHost(name: "studio", shell: shell("/bin/sh"), facts: facts)

        XCTAssertThrowsError(try host.files(matching: "\(root.path)/out/*.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "\(root.path)/out/*.md could not be looked at: studio could not describe a file it matches")
        }
        XCTAssertThrowsError(try host.file(at: "\(root.path)/out/a.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "\(root.path)/out/a.md could not be looked at: studio could not describe the file")
        }
        XCTAssertEqual(try host.files(matching: "\(root.path)/out/*.txt"), [])
    }

    func testARelativePathCannotBeReadAsAnOption() throws {
        XCTAssertEqual(RemoteHost.anchored("-f"), "./-f")
        XCTAssertEqual(RemoteHost.anchored("logs/x"), "./logs/x")
        XCTAssertEqual(RemoteHost.anchored("./x"), "./x")
        XCTAssertEqual(RemoteHost.anchored("/var/log/x"), "/var/log/x")
        try inEveryShell { host in
            XCTAssertEqual(host.contents(ofFileAt: "-f"), .missing)
            XCTAssertEqual(try host.read("-n", range: 0..<5), Data())
            XCTAssertNil(try host.file(at: "-e"))
            XCTAssertEqual(host.plistNames(in: "-P"), [])
        }
    }

    func testFoldersOnTheWay() {
        XCTAssertEqual(RemoteHost.folders(on: "/var/log/app/*.log"), [
            .init(path: "/var", mustBeListable: false),
            .init(path: "/var/log", mustBeListable: false),
            .init(path: "/var/log/app", mustBeListable: true)
        ])
        XCTAssertEqual(RemoteHost.folders(on: "/var/log/app.log"), [
            .init(path: "/var", mustBeListable: false),
            .init(path: "/var/log", mustBeListable: false)
        ])
        XCTAssertEqual(RemoteHost.folders(on: "/data/*/out/x"), [.init(path: "/data", mustBeListable: true)])
        XCTAssertEqual(RemoteHost.folders(on: "/x"), [])
        XCTAssertEqual(RemoteHost.folders(on: "/*.log"), [])
        XCTAssertEqual(RemoteHost.folders(on: "relative/x"), [])
    }

    // MARK: - Reading

    func testReadingAPartOfAFile() throws {
        let path = try write("run.log", "0123456789")
        try inEveryShell { host in
            XCTAssertEqual(try host.read(path, range: 0..<4), Data("0123".utf8))
            XCTAssertEqual(try host.read(path, range: 3..<6), Data("345".utf8))
            XCTAssertEqual(try host.read(path, range: 8..<100), Data("89".utf8))
            XCTAssertEqual(try host.read(path, range: 10..<20), Data())
            XCTAssertEqual(try host.read(path, range: 50..<60), Data())
            XCTAssertEqual(try host.read(path, range: 4..<4), Data())
            XCTAssertEqual(try host.read("~/run.log", range: 0..<2), Data("01".utf8))
        }
    }

    func testBytesComeBackAsTheyAre() throws {
        let bytes = Data((0...255).map { UInt8($0) })
        let path = try write("binary.dat", data: bytes)
        try inEveryShell { host in
            XCTAssertEqual(try host.read(path, range: 0..<256), bytes)
            XCTAssertEqual(try host.read(path, range: 250..<256), bytes.suffix(6))
        }
    }

    func testReadingAFileThatIsNotThereIsEmpty() throws {
        try inEveryShell { host in
            XCTAssertEqual(try host.read("\(root.path)/none.log", range: 0..<10), Data())
        }
    }

    func testReadingAFileWithoutPermissionIsAnError() throws {
        let path = try write("secret.log", "x")
        try lock("secret.log")
        try inEveryShell { host in
            XCTAssertThrowsError(try host.read(path, range: 0..<10)) { error in
                XCTAssertEqual((error as? HostAccessError)?.message, "\(path) could not be read: permission denied")
            }
        }
    }
}
