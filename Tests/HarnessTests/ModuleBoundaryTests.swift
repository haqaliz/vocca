import XCTest

/// Raised when the package root cannot be located by walking up from the test file's path.
private enum ModuleBoundaryTestError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
        }
    }
}

/// Enforces the module dependency rules for the Vocca package's `Sources/` tree:
///
/// 1. No leaf module imports `VoccaCore`.
/// 2. No leaf module imports another leaf module.
/// 3. `VoccaUI` imports only `VoccaCore` among Vocca modules.
final class ModuleBoundaryTests: XCTestCase {
    private static let leafModules: Set<String> = [
        "VoccaAudio", "VoccaHotkey", "VoccaASR", "VoccaText", "VoccaInject", "VoccaSpeech",
    ]

    /// Walks up from `filePath` until it finds the directory containing `Package.swift`,
    /// then returns that directory's `Sources` subdirectory. Never hardcodes an absolute path.
    private func findSourcesRoot(from filePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent("Sources")
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ModuleBoundaryTestError.packageRootNotFound(startingFrom: filePath)
    }

    private func swiftFiles(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    private func importedModuleNames(in file: URL) throws -> [String] {
        let content = try String(contentsOf: file, encoding: .utf8)
        var result: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            let afterImport = trimmed.dropFirst("import ".count)
            guard let firstToken = afterImport.split(separator: " ").first else { continue }
            result.append(String(firstToken))
        }
        return result
    }

    /// Maps each module directory name under `Sources/` to the set of module names it imports,
    /// by reading `import` lines from every `.swift` file inside that directory.
    private func moduleImportMap() throws -> [String: Set<String>] {
        let sourcesRoot = try findSourcesRoot(from: #filePath)
        let moduleDirs = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey])
        var map: [String: Set<String>] = [:]
        for moduleDir in moduleDirs {
            let isDir = (try? moduleDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let moduleName = moduleDir.lastPathComponent
            var imports: Set<String> = []
            for file in swiftFiles(under: moduleDir) {
                imports.formUnion(try importedModuleNames(in: file))
            }
            map[moduleName] = imports
        }
        return map
    }

    func testNoLeafModuleImportsVoccaCore() throws {
        let map = try moduleImportMap()
        for leaf in Self.leafModules {
            let imports = map[leaf] ?? []
            XCTAssertFalse(
                imports.contains("VoccaCore"),
                "\(leaf) must not import VoccaCore, found imports: \(imports)")
        }
    }

    func testNoLeafModuleImportsAnotherLeafModule() throws {
        let map = try moduleImportMap()
        for leaf in Self.leafModules {
            let imports = map[leaf] ?? []
            let violations = imports.intersection(Self.leafModules.subtracting([leaf]))
            XCTAssertTrue(
                violations.isEmpty,
                "\(leaf) must not import other leaf modules, found: \(violations)")
        }
    }

    func testVoccaUIImportsOnlyVoccaCoreAmongVoccaModules() throws {
        let map = try moduleImportMap()
        let voccaModuleNames = Set(map.keys)
        let uiImports = map["VoccaUI"] ?? []
        let voccaImportsFromUI = uiImports.intersection(voccaModuleNames)
        XCTAssertTrue(
            voccaImportsFromUI.isSubset(of: ["VoccaCore"]),
            "VoccaUI must import only VoccaCore among Vocca modules, found: \(voccaImportsFromUI)")
    }
}
