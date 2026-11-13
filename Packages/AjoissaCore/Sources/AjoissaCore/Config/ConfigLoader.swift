import Foundation

/// Reads a config file and checks it against every rule before anything else uses it.
///
/// The file is JSON5: JSON with comments, trailing commas and unquoted keys.
public enum ConfigLoader {
    public static func load(contentsOf url: URL) throws(ConfigError) -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: url.path, reason: error.localizedDescription)
        }
        return try load(data)
    }

    public static func load(_ data: Data) throws(ConfigError) -> Config {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw .syntax(message: detail ?? error.localizedDescription)
        }
        guard let values = root as? [String: Any] else {
            throw .invalid([ConfigIssue(path: "", message: "The file must contain one object with version, hosts and jobs.")])
        }
        let issues = IssueCollector()
        DuplicateKeyScanner.duplicates(in: data).forEach { issues.add("line \($0.line)", $0.message) }
        let config = ConfigParser(issues: issues).config(from: values)
        guard issues.issues.isEmpty else {
            throw .invalid(issues.issues)
        }
        return config
    }
}

/// Turns the parsed file into a ``Config``, reporting every broken rule to its collector.
/// The result is only meaningful when the collector stays empty.
struct ConfigParser {
    let issues: IssueCollector

    func config(from values: [String: Any]) -> Config {
        var root = ObjectReader(path: "", values: values, issues: issues)
        version(&root)
        let (hosts, declaredHostIDs) = hosts(&root)
        let jobs = jobs(&root, hostIDs: declaredHostIDs)
        root.finish()
        return Config(hosts: hosts, jobs: jobs)
    }

    private func version(_ root: inout ObjectReader) {
        guard root.has("version") else {
            root.report("version", "is required; use \(Config.supportedVersion)")
            return
        }
        guard let version = root.integer("version"), version != Config.supportedVersion else { return }
        root.report("version", "is \(version), but this version of Ajoissa only reads version \(Config.supportedVersion)")
    }

    /// - Returns: The valid hosts, and the id of every host the file tried to define. Jobs are checked against the
    ///   second, so a host with a mistake in it does not also produce an "unknown host" for each of its jobs.
    private func hosts(_ root: inout ObjectReader) -> (hosts: [Host], declaredIDs: Set<String>) {
        var hosts = [Host.local]
        var declaredIDs: Set<String> = [Host.localID]
        for var reader in root.elements("hosts") {
            let id = identifier(&reader, taken: Array(declaredIDs), reserved: Host.localID)
            let alias = sshAlias(&reader)
            let mayBeOffline = reader.bool("mayBeOffline") ?? false
            reader.finish()
            if let id {
                declaredIDs.insert(id)
            }
            if let id, let alias {
                hosts.append(Host(id: id, connection: .ssh(alias: alias), mayBeOffline: mayBeOffline))
            }
        }
        return (hosts, declaredIDs)
    }

    private func sshAlias(_ reader: inout ObjectReader) -> String? {
        guard let alias = reader.requiredString("ssh") else { return nil }
        guard Self.isPlainName(alias) else {
            reader.report("ssh", "must be a host alias from ~/.ssh/config: \(Self.plainNameRule)")
            return nil
        }
        return alias
    }

    /// Reads and checks the `id` of a host or job.
    /// - Parameter reserved: An id that exists without being defined in the file, and so cannot be defined in it.
    func identifier(_ reader: inout ObjectReader, taken: [String], reserved: String? = nil) -> String? {
        guard let id = reader.requiredString("id") else { return nil }
        guard Self.isIdentifier(id) else {
            reader.report("id", "may only contain lower-case letters, digits, \".\", \"-\" and \"_\", and must start with a letter or digit")
            return nil
        }
        guard !taken.contains(id) else {
            reader.report("id", id == reserved ? "\"\(id)\" always means this Mac and cannot be redefined" : "is used more than once")
            return nil
        }
        return id
    }

    static func isIdentifier(_ text: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789._-"
        guard let first = text.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return text.count <= 64 && text.allSatisfy(allowed.contains)
    }

    static let plainNameRule = "letters, digits, \".\", \"_\" and \"-\" only, and not starting with \"-\""

    static func isPlainName(_ text: String, extra: String = "") -> Bool {
        PlainName.isValid(text, extra: extra)
    }
}
