import Foundation

extension ConfigParser {
    func jobs(_ root: inout ObjectReader, hostIDs: Set<String>) -> [Job] {
        guard root.has("jobs") else {
            root.report("jobs", "is required; it is a list and may be empty")
            return []
        }
        var jobs: [Job] = []
        var seenIDs: [String] = []
        for var reader in root.elements("jobs") {
            let id = identifier(&reader, taken: seenIDs)
            if let id {
                seenIDs.append(id)
            }
            if let job = job(&reader, id: id, hostIDs: hostIDs) {
                jobs.append(job)
            }
            reader.finish()
        }
        return jobs
    }

    private func job(_ reader: inout ObjectReader, id: String?, hostIDs: Set<String>) -> Job? {
        let name = reader.line("name")
        let hostID = host(&reader, known: hostIDs)
        let source = source(&reader)
        let schedule = schedule(&reader)
        let grace = reader.duration("grace") ?? Job.defaultGrace
        let notify = reader.bool("notify") ?? true
        // A source that was given but is wrong has already been reported; do not also complain about a log path.
        let sourceIsUnknown = reader.has("source") && source == nil
        let checks = checks(&reader, logPathAvailable: source?.providesLogPath ?? sourceIsUnknown)
        crossRules(reader, hostID: hostID, source: source)
        guard let id, let hostID else { return nil }
        return Job(
            id: id,
            name: name ?? id,
            hostID: hostID,
            source: source,
            schedule: schedule,
            grace: grace,
            notify: notify,
            checks: checks
        )
    }

    /// Rules that span more than one setting of a job.
    private func crossRules(_ reader: ObjectReader, hostID: String?, source: JobSource?) {
        if !reader.has("source") {
            if !reader.has("schedule") {
                reader.report("schedule", "is required for a job without a source, because there is nowhere to read the schedule from")
            }
            if reader.count(of: "checks") == 0 {
                reader.reportSelf("needs a source or at least one check; otherwise there is no way to tell whether it ran")
            }
        }
        if case .systemd = source, hostID == Host.localID {
            reader.report("source", "systemd needs a Linux host, but this job runs on \"local\", which is this Mac")
        }
    }

    private func host(_ reader: inout ObjectReader, known: Set<String>) -> String? {
        guard reader.has("host") else { return Host.localID }
        guard let id = reader.string("host") else { return nil }
        guard known.contains(id) else {
            reader.report("host", "is \"\(id)\", which is not defined under hosts")
            return nil
        }
        return id
    }

    private func source(_ job: inout ObjectReader) -> JobSource? {
        guard var reader = job.object("source") else { return nil }
        guard let kind = onlyKind(in: reader, of: ["launchd", "systemd", "cron"]) else { return nil }
        let source: JobSource? = switch kind {
        case "launchd":
            launchdLabel(&reader).map { .launchd(label: $0) }
        case "systemd":
            systemd(&reader)
        default:
            reader.line("cron").map { .cron(matching: $0) }
        }
        reader.finish()
        return source
    }

    private func systemd(_ reader: inout ObjectReader) -> JobSource? {
        let unit = reader.string("systemd")
        var scope = JobSource.SystemdScope.system
        if let text = reader.string("scope") {
            guard let given = JobSource.SystemdScope(rawValue: text) else {
                reader.report("scope", "must be \"system\" or \"user\"")
                return nil
            }
            scope = given
        }
        guard let unit else { return nil }
        guard Self.isUnitName(unit) else {
            reader.report("systemd", "must be a unit name such as \"backup.timer\": letters, digits, \".\", \"_\", \"-\", \"@\" and \":\" only, not starting with \"-\", and ending in .timer or .service")
            return nil
        }
        return .systemd(unit: unit, scope: scope)
    }

    private func schedule(_ job: inout ObjectReader) -> Schedule? {
        guard var reader = job.object("schedule") else { return nil }
        guard let kind = onlyKind(in: reader, of: ["daily", "weekly", "every"]) else { return nil }
        let schedule: Schedule? = switch kind {
        case "daily":
            reader.timeOfDay("daily").map { .daily(at: $0) }
        case "weekly":
            weekly(&reader)
        default:
            every(&reader)
        }
        reader.finish()
        return schedule
    }

    private func weekly(_ schedule: inout ObjectReader) -> Schedule? {
        guard var reader = schedule.object("weekly") else { return nil }
        var day: Weekday?
        if let text = reader.requiredString("day") {
            day = Weekday(rawValue: text)
            if day == nil {
                reader.report("day", "must be one of \(Weekday.allCases.map(\.rawValue).joined(separator: ", "))")
            }
        }
        let time = reader.timeOfDay("at")
        reader.finish()
        guard let day, let time else { return nil }
        return .weekly(on: day, at: time)
    }

    private func every(_ reader: inout ObjectReader) -> Schedule? {
        guard let interval = reader.duration("every") else { return nil }
        guard interval >= Schedule.minimumInterval else {
            reader.report("every", "must be at least 1m")
            return nil
        }
        return .every(interval)
    }

    /// The one setting out of `kinds` that the object has. Reports the object when it has none or several.
    private func onlyKind(in reader: ObjectReader, of kinds: [String]) -> String? {
        let present = kinds.filter(reader.has)
        guard present.count == 1 else {
            reader.reportSelf("must have exactly one of \(kinds.joined(separator: ", "))")
            return nil
        }
        return present[0]
    }

    private func launchdLabel(_ reader: inout ObjectReader) -> String? {
        guard let label = reader.string("launchd") else { return nil }
        guard Self.isPlainName(label) else {
            reader.report("launchd", "must be a launchd label: \(Self.plainNameRule)")
            return nil
        }
        return label
    }

    /// A timer or service unit with a name of its own: not a bare suffix and not a template such as `job@.service`.
    static func isUnitName(_ unit: String) -> Bool {
        guard isPlainName(unit, extra: "@:"), let suffix = [".timer", ".service"].first(where: unit.hasSuffix) else {
            return false
        }
        let stem = unit.dropLast(suffix.count)
        return !stem.isEmpty && !stem.hasSuffix("@")
    }
}

private extension JobSource {
    /// Whether the job's own definition says where its log file is.
    var providesLogPath: Bool {
        if case .launchd = self { true } else { false }
    }
}
