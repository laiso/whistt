import Foundation

public enum EnvLoader {
    public static private(set) var lastTriedPaths: [URL] = []

    public static func value(for key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty {
            return v
        }
        let paths = searchPaths()
        lastTriedPaths = paths
        return value(for: key, searching: paths)
    }

    public static func value(for key: String, searching paths: [URL]) -> String? {
        for url in paths {
            if let v = readKey(key, from: url) {
                NSLog("[Whistt] loaded %@ from %@", key, url.path)
                return v
            }
        }
        return nil
    }

    private static func searchPaths() -> [URL] {
        var paths: [URL] = []

#if DEBUG
        // Source-file-relative project root (resolved at compile time via #filePath).
        // DEBUG-only so release builds don't embed the build machine's absolute path.
        if let projectRoot = compiledProjectRoot() {
            paths.append(projectRoot.appendingPathComponent(".env"))
        }
#endif

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var current = cwd
        for _ in 0..<6 {
            paths.append(current.appendingPathComponent(".env"))
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        var bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            paths.append(bundleDir.appendingPathComponent(".env"))
            let parent = bundleDir.deletingLastPathComponent()
            if parent.path == bundleDir.path { break }
            bundleDir = parent
        }

        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let homeURL = URL(fileURLWithPath: home)
            paths.append(homeURL.appendingPathComponent(".whistt/.env"))
            paths.append(homeURL.appendingPathComponent(".config/whistt/.env"))
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

#if DEBUG
    // Resolved at compile time. Source file path: <repo>/Whistt/Whistt/EnvLoader.swift
    // Walk up three components to reach <repo>.
    private static func compiledProjectRoot(file: String = #filePath) -> URL? {
        let fileURL = URL(fileURLWithPath: file)
        let candidate = fileURL
            .deletingLastPathComponent() // Whistt/Whistt/
            .deletingLastPathComponent() // Whistt/
            .deletingLastPathComponent() // repo root
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
#endif

    private static func readKey(_ key: String, from url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if v.isEmpty { return nil }
            warnIfPermissive(url)
            return v
        }
        return nil
    }

    // .env holds API keys — warn (don't fail) when group/world bits are set.
    private static func warnIfPermissive(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? NSNumber else { return }
        let mode = perms.uint16Value
        if (mode & 0o044) != 0 {
            NSLog("[Whistt] warning: %@ is readable by group/other (mode %o); chmod 600 recommended",
                  url.path, mode)
        }
    }
}
