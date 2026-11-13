import Foundation

/// Where the config file is.
public enum ConfigLocation {
    /// The environment variable that names a config file other than the default one.
    public static let environmentVariable = "AJOISSA_CONFIG"

    /// The default config file, relative to the home directory.
    public static let defaultRelativePath = ".config/ajoissa/config.json5"

    /// The config file to use: an explicit path first, then `AJOISSA_CONFIG`, then the default under the home directory.
    ///
    /// - Parameters:
    ///   - explicitPath: A path given by the user for this run, such as a command line flag.
    ///   - environment: The process environment.
    ///   - homeDirectory: The user's home directory.
    public static func resolve(
        explicitPath: String?,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let chosen = [explicitPath, environment[environmentVariable]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let chosen else {
            return homeDirectory.appending(path: defaultRelativePath, directoryHint: .notDirectory)
        }
        if chosen == "~" || chosen.hasPrefix("~/") {
            return homeDirectory.appending(path: String(chosen.dropFirst(2)), directoryHint: .notDirectory)
        }
        return URL(fileURLWithPath: chosen)
    }
}
