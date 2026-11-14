import Foundation

/// Every script Ajoissa runs on another machine. There are no others: this file is the list.
///
/// Each is a few lines of POSIX shell, read by `/bin/sh` from its input. All of them only read, except
/// ``run(_:)``, which starts the program of a `command` check that the user wrote in the config, and
/// `launchctl print`, which is itself read-only.
///
/// A value from the config appears in a script only through ``ShellQuoting/quote(_:)``, as one quoted word.
/// Numbers are written by Ajoissa itself. Every script ends by reporting a status after
/// ``RemoteShell/marker`` on its error output.
///
/// The README lists the same scripts in words; keep the two in step.
enum RemoteCommands {
    /// How a machine's `stat` is asked for a file's modification time, size and identity.
    enum StatFlavour: Sendable, Equatable {
        /// macOS and the BSDs.
        case bsd
        /// Linux.
        case gnu

        var command: String {
            switch self {
            case .bsd: "stat -L -f '%m %z %i'"
            case .gnu: "stat -L -c '%Y %s %i'"
            }
        }
    }

    /// A folder on the way to a file, and whether it must be listable as well as enterable.
    struct Folder: Equatable {
        var path: String
        var mustBeListable: Bool
    }

    private static func q(_ value: String) -> String {
        ShellQuoting.quote(value)
    }

    private static func report(_ status: String) -> String {
        "printf '\(RemoteShell.marker)%s\\n' \(q(status)) >&2"
    }

    /// What the machine is: its system, the user's id and home folder, its clock, when it started and woke,
    /// and its time zone. Seven lines; one that cannot be told is empty.
    static let probe = """
        uname -s
        id -u
        printf '%s\\n' "$HOME"
        date +%s
        sysctl -n kern.boottime 2>/dev/null || echo
        sysctl -n kern.waketime 2>/dev/null || echo
        readlink /etc/localtime 2>/dev/null || echo
        \(report("ok"))
        """

    /// Reports `unsearchable` and stops if one of the folders exists but cannot be entered, or cannot be
    /// listed where that is needed. Used when nothing was found, to tell "not there" from "cannot look".
    private static func refuseUnsearchable(_ folders: [Folder]) -> String {
        folders.map { folder in
            let test = folder.mustBeListable ? "{ [ ! -x \"$d\" ] || [ ! -r \"$d\" ]; }" : "[ ! -x \"$d\" ]"
            return "d=\(q(folder.path)); if [ -d \"$d\" ] && \(test); then \(report("unsearchable")); exit 0; fi"
        }.joined(separator: "\n")
    }

    /// The regular files a pattern matches, each as "modified size identity path" followed by a NUL.
    /// Reports `toomany` when there are more than `limit`.
    static func files(matching pattern: String, folders: [Folder], limit: Int, stat: StatFlavour) -> String {
        """
        p=\(q(pattern))
        IFS=
        set -- $p
        n=0
        for f in "$@"; do
          [ -f "$f" ] || continue
          n=$((n+1))
          if [ "$n" -gt \(limit) ]; then \(report("toomany")); exit 0; fi
          s=$(\(stat.command) "$f" 2>/dev/null) || continue
          printf '%s %s\\0' "$s" "$f"
        done
        if [ "$n" -eq 0 ]; then
        :
        \(refuseUnsearchable(folders))
        fi
        \(report("ok"))
        """
    }

    /// The regular file at exactly this path, in the same form as ``files(matching:folders:limit:stat:)``,
    /// or nothing when there is none.
    static func file(at path: String, folders: [Folder], stat: StatFlavour) -> String {
        """
        f=\(q(path))
        if [ -f "$f" ]; then
          s=$(\(stat.command) "$f" 2>/dev/null) && printf '%s %s\\0' "$s" "$f"
        elif [ ! -e "$f" ]; then
        :
        \(refuseUnsearchable(folders))
        fi
        \(report("ok"))
        """
    }

    /// The bytes of a file from `offset`, at most `count` of them; all of the rest when `count` is `nil`.
    /// Reports `missing` when there is no such file and `unreadable` when it may not be read.
    static func read(_ path: String, from offset: Int64, count: Int64?) -> String {
        let take = count.map { " | head -c \($0)" } ?? ""
        return """
            f=\(q(path))
            if [ ! -e "$f" ]; then \(report("missing")); exit 0; fi
            if [ ! -f "$f" ] || [ ! -r "$f" ]; then \(report("unreadable")); exit 0; fi
            tail -c +\(offset + 1) "$f"\(take)
            \(report("ok"))
            """
    }

    /// The names of the files in a folder that end in `.plist`, each followed by a NUL.
    /// Reports `missing` when there is no such folder and `unreadable` when it may not be listed.
    static func plistNames(in folder: String) -> String {
        """
        d=\(q(folder))
        if [ ! -d "$d" ]; then \(report("missing")); exit 0; fi
        if [ ! -r "$d" ] || [ ! -x "$d" ]; then \(report("unreadable")); exit 0; fi
        cd "$d" || { \(report("unreadable")); exit 0; }
        for f in *.plist; do
          [ -e "$f" ] && printf '%s\\0' "$f"
        done
        \(report("ok"))
        """
    }

    /// Runs a program with its arguments as they are, reading nothing, and reports `exit <code>`.
    /// Reports `notfound` when there is no such program to run.
    static func run(_ arguments: [String]) -> String {
        let program = q(arguments.first ?? "")
        return """
            if [ ! -x \(program) ] || [ -d \(program) ]; then \(report("notfound")); exit 0; fi
            \(arguments.map(q).joined(separator: " ")) </dev/null
            printf '\(RemoteShell.marker)exit %s\\n' "$?" >&2
            """
    }
}
