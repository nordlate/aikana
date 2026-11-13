import Foundation

extension ConfigParser {
    static let checkTypes = ["file-age", "file-size", "command", "log-pattern"]

    /// - Parameter logPathAvailable: Whether a `log-pattern` check may leave out its path.
    func checks(_ job: inout ObjectReader, logPathAvailable: Bool) -> [Check] {
        job.elements("checks").compactMap { element in
            var reader = element
            return check(&reader, logPathAvailable: logPathAvailable)
        }
    }

    private func check(_ reader: inout ObjectReader, logPathAvailable: Bool) -> Check? {
        guard let type = reader.requiredString("type") else { return nil }
        let check: Check?
        switch type {
        case "file-age":
            check = fileAge(&reader)
        case "file-size":
            check = fileSize(&reader)
        case "command":
            check = command(&reader)
        case "log-pattern":
            check = logPattern(&reader, pathIsOptional: logPathAvailable)
        default:
            reader.report("type", "is \"\(type)\", but must be one of \(Self.checkTypes.joined(separator: ", "))")
            return nil
        }
        reader.finish()
        return check
    }

    private func fileAge(_ reader: inout ObjectReader) -> Check? {
        let path = path(&reader, required: true)
        let maxAge = reader.duration("maxAge")
        return path.map { .fileAge(path: $0, maxAge: maxAge) }
    }

    private func fileSize(_ reader: inout ObjectReader) -> Check? {
        let path = path(&reader, required: true)
        guard let text = reader.requiredString("minSize") else { return nil }
        guard let minBytes = ConfigValues.byteCount(text), minBytes > 0 else {
            reader.report("minSize", "must be a size such as \"500KB\", \"10MB\" or \"1GB\"")
            return nil
        }
        return path.map { .fileSize(path: $0, minBytes: minBytes) }
    }

    private func command(_ reader: inout ObjectReader) -> Check? {
        var timeout = Check.defaultCommandTimeout
        if let given = reader.duration("timeout") {
            if given > Check.maximumCommandTimeout {
                reader.report("timeout", "must be at most 10m")
            } else {
                timeout = given
            }
        }
        guard reader.has("run") else {
            reader.report("run", "is required")
            return nil
        }
        guard let list = reader.array("run") else { return nil }
        guard let arguments = list as? [String], let program = arguments.first, !program.isEmpty else {
            reader.report("run", "must be a list of strings: the program, then its arguments, such as [\"/usr/bin/true\"]")
            return nil
        }
        guard program.hasPrefix("/") || program.hasPrefix("~/") else {
            reader.report("run", "must start with the program's absolute path, such as \"/usr/bin/true\", because the search path differs between machines")
            return nil
        }
        return .command(arguments: arguments, timeout: timeout)
    }

    private func logPattern(_ reader: inout ObjectReader, pathIsOptional: Bool) -> Check? {
        let hasPath = reader.has("path")
        let path = path(&reader, required: false)
        if !hasPath, !pathIsOptional {
            reader.report("path", "is required unless the job's source is launchd, whose log file is then used")
        }
        let contains = reader.line("contains")
        let notContains = reader.line("notContains")
        guard reader.has("contains") || reader.has("notContains") else {
            reader.reportSelf("needs contains or notContains")
            return nil
        }
        return .logPattern(path: path, contains: contains, notContains: notContains)
    }

    private func path(_ reader: inout ObjectReader, required: Bool) -> String? {
        if required, !reader.has("path") {
            reader.report("path", "is required")
            return nil
        }
        guard let path = reader.line("path") else { return nil }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else {
            reader.report("path", "must be an absolute path, or start with ~/ for the home directory on the job's host")
            return nil
        }
        return path
    }
}
