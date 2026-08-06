// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Finding `.swift` files and reading the `import` lines out of them, once, for every suite that
/// lints the source tree.
///
/// This was `ModuleBoundaryTests`' private implementation. It moved here when a second lint
/// (`CoreBoundaryTests`, which forbids system-framework imports in `VoccaCore`) needed the same
/// parse, because the parse is where the subtle mistakes live and a second copy would have
/// repeated them: the forms below were each added to this parser after a version that missed them.
/// The package-root walk had already been copied five times before it was consolidated
/// (see ``PackageRootLocator``); this is the same debt caught one copy earlier.
///
/// Deliberately *not* a Swift parser. It reads text, which is what makes it usable from a test
/// with no build-system integration — and it is why comments are stripped first rather than
/// pattern-matched around.
///
/// **Known limit:** it is not string-literal aware. ``stripComments(from:)`` will treat `/*` inside
/// a string literal as opening a block comment, and ``importedModuleNames(inSource:)`` splits on
/// `;` inside literals too. Both usually fail towards *over*-reporting, which is the safe
/// direction for a boundary lint — with one exception worth knowing: an unterminated `/*` inside a
/// multi-line or raw string literal would swallow every import below it in that file. No file in
/// `Sources/` contains one today, and a Swift-syntax dependency in the harness costs more than the
/// risk; if that changes, this is the thing to fix first.
enum SwiftSourceScanner {

    /// One `import` statement, as the text scan understands it.
    struct ImportStatement: Equatable {
        /// The leading component of the imported path — the module itself.
        let module: String
        /// `true` for `@_exported import`, which makes the imported module's API visible to
        /// everything that imports *this* one. That is invisible to a lint that only reads the
        /// importing file, so it is surfaced rather than flattened away.
        let isReExported: Bool
    }

    /// Non-attribute tokens that can precede the `import` keyword: the SE-0409 access-level
    /// import modifiers. Order between these and any attributes isn't fixed, so the prefix is
    /// stripped in a loop rather than checked positionally.
    ///
    /// Attributes are handled separately and by *shape* — any leading token beginning with `@` is
    /// stripped — rather than by an allow-list. An allow-list containing only `@testable` was the
    /// state of this parser until `@_implementationOnly import CoreGraphics.CGEvent` was used to
    /// smuggle an import past it: the token did not match, so the line was not recognised as an
    /// import at all and the module was reported as clean. `@preconcurrency`, `@_exported` and
    /// `@_spi(...)` would each have done the same. There is no finite list of import attributes
    /// worth trusting here, and the cost of the general rule is nil: nothing else in Swift puts an
    /// `@`-token immediately before the `import` keyword.
    static let importPrefixModifiers: Set<String> = [
        "public", "internal", "package", "private", "fileprivate",
    ]

    /// Kind qualifiers usable after `import` for a scoped import, e.g. `import struct Mod.Type`.
    static let importKindQualifiers: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
    ]

    /// Every `.swift` file at or below `root`, in whatever order the enumerator yields.
    ///
    /// Returns an empty array rather than throwing when `root` does not exist. Callers must treat
    /// "no files" as a failure of their own check, not as a pass — see the vacuity guards in
    /// ``ModuleBoundaryTests`` and ``CoreBoundaryTests``.
    static func swiftFiles(under root: URL) -> [URL] {
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

    /// Removes `//` line comments and `/* ... */` block comments from Swift source text before
    /// it is scanned for `import` lines, so a commented-out import is never counted as real.
    /// Block comments are treated as non-nested, which matches every file this package writes.
    static func stripComments(from source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var inBlockComment = false
        while i < chars.count {
            if inBlockComment {
                if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    if chars[i] == "\n" { result.append("\n") }
                    i += 1
                }
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Extracts the module name from every `import` in `source`, tolerating:
    /// - any leading attribute (`@testable`, `@preconcurrency`, `@_implementationOnly`, ...)
    /// - access-level modifiers (`public import`, `internal import`, `package import`, ...)
    /// - kind-qualified imports (`import struct Mod.Type`, `import func Mod.f`, ...)
    /// - submodule imports (`import Mod.Submodule`) — only the leading component is the module
    /// - a trailing `;`, and several statements separated by `;` on one line
    ///
    /// Each of those forms is here because a lint in this repository was, or would have been,
    /// blind to it. An import a lint cannot see is an import that lint permits, and a lint that
    /// permits the one form someone reaches for is not a boundary.
    static func importStatements(inSource source: String) -> [ImportStatement] {
        // `;` separates statements, so it both terminates an import and can put a second one on
        // the same physical line. Treating it as a line break handles both.
        let withoutComments = stripComments(from: source)
            .replacingOccurrences(of: ";", with: "\n")
        var result: [ImportStatement] = []
        for rawLine in withoutComments.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            var tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)

            var isReExported = false
            while let first = tokens.first,
                importPrefixModifiers.contains(first) || first.hasPrefix("@")
            {
                if first == "@_exported" { isReExported = true }
                tokens.removeFirst()
            }
            guard tokens.first == "import" else { continue }
            tokens.removeFirst()

            if let first = tokens.first, importKindQualifiers.contains(first) {
                tokens.removeFirst()
            }
            guard let modulePath = tokens.first else { continue }

            let moduleName = modulePath.split(separator: ".").first.map(String.init) ?? modulePath
            result.append(ImportStatement(module: moduleName, isReExported: isReExported))
        }
        return result
    }

    /// ``importStatements(inSource:)`` applied to a file on disk.
    static func importStatements(in file: URL) throws -> [ImportStatement] {
        importStatements(inSource: try String(contentsOf: file, encoding: .utf8))
    }

    static func importedModuleNames(inSource source: String) -> [String] {
        importStatements(inSource: source).map(\.module)
    }

    /// ``importedModuleNames(inSource:)`` applied to a file on disk.
    static func importedModuleNames(in file: URL) throws -> [String] {
        importedModuleNames(inSource: try String(contentsOf: file, encoding: .utf8))
    }

    // MARK: - Reading the inside of a declaration

    /// The text between the brace at `openingBraceIndex` and its match, or `nil` if the braces
    /// never balance.
    ///
    /// Shared rather than copied, on the same reasoning as the parse above: ``DeinitIsolationTests``
    /// needed the body of every `deinit` and ``RealtimeSafetyTests`` needs the body of every
    /// function marked as running on the realtime thread. Those are the same ten lines, and this
    /// repository has already paid once for five copies of a directory walk that were five chances
    /// to diverge.
    ///
    /// It inherits this type's known limit — it is not string-literal aware, so a `{` inside a
    /// literal unbalances the body. That fails towards reading *too much*, and therefore towards
    /// over-reporting, which is the safe direction for a lint.
    /// Returns the body text and the index of the closing brace, so a caller scanning for several
    /// declarations can resume immediately after it without re-deriving the position from the
    /// body's length.
    static func bracedBody(
        in text: [Character], openingBraceIndex: Int
    ) -> (body: String, closingBraceIndex: Int)? {
        guard openingBraceIndex < text.count, text[openingBraceIndex] == "{" else { return nil }
        var depth = 0
        var end = openingBraceIndex
        while end < text.count {
            if text[end] == "{" { depth += 1 }
            if text[end] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(text[(openingBraceIndex + 1)..<end]), end)
                }
            }
            end += 1
        }
        return nil
    }

    /// Every name called in `body`: the identifier immediately preceding a `(`.
    ///
    /// Names rather than full expressions, because the rules built on this are about *what is
    /// reached* and the receiver is irrelevant — `timer.stop()` and `self.timer.stop()` are the
    /// same call.
    ///
    /// **It cannot see a call with no parentheses.** `Task { … }` is a call written entirely in
    /// trailing-closure form and does not appear here at all. Any lint that must forbid such a
    /// construct needs a second pass over the identifiers; ``RealtimeSafetyTests`` has one, and it
    /// is there because this function structurally cannot.
    static func callNames(inBody body: String) -> Set<String> {
        var names: Set<String> = []
        var current = ""

        for character in body {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                if character == "(", !current.isEmpty { names.insert(current) }
                current = ""
            }
        }
        return names
    }

    /// Every identifier in `body`, as whole words.
    ///
    /// The companion to ``callNames(inBody:)`` for rules that must catch constructs written without
    /// parentheses — `await`, `try`, `throw`, and `Task { … }`.
    static func identifiers(inBody body: String) -> Set<String> {
        var names: Set<String> = []
        var current = ""

        for character in body {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                if !current.isEmpty { names.insert(current) }
                current = ""
            }
        }
        if !current.isEmpty { names.insert(current) }
        return names
    }
}
