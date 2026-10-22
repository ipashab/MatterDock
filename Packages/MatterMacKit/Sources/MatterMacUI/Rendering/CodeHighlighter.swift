import Foundation

/// Минимальная подсветка код-блоков (ADR 0053): комментарии, строки, числа и
/// ключевые слова для python, bash, js/ts, json, go и sql. Лексер однократный,
/// O(n) по символам; незнакомый язык или отсутствие метки — без подсветки.
/// Никаких внешних движков: профили языков намеренно крошечные — этого
/// достаточно, чтобы читать код, это не редактор.
nonisolated enum CodeHighlighter {
    enum Kind: Sendable, Hashable {
        case keyword
        case string
        case comment
        case number
    }

    struct Segment: Sendable, Hashable {
        let text: String
        let kind: Kind?
    }

    /// Выделенные сегменты кода; соседние неокрашенные куски слиты в один.
    static func segments(_ code: String, language rawLanguage: String?) -> [Segment] {
        guard let language = rawLanguage?.lowercased().trimmingCharacters(in: .whitespaces),
              let profile = profiles[language] else { return [] }
        let chars = Array(code)
        var segments: [Segment] = []
        var plain = ""
        var index = 0

        func flush() {
            guard !plain.isEmpty else { return }
            segments.append(Segment(text: plain, kind: nil))
            plain = ""
        }
        func matches(_ literal: [Character], at position: Int) -> Bool {
            guard position + literal.count <= chars.count else { return false }
            for (offset, char) in literal.enumerated() where chars[position + offset] != char { return false }
            return true
        }
        func isIdentifierStart(_ char: Character) -> Bool {
            (char.isLetter && char.isASCII) || char == "_" || char == "$"
        }
        func isIdentifierPart(_ char: Character) -> Bool {
            (char.isLetter && char.isASCII) || (char.isNumber && char.isASCII) || char == "_" || char == "$"
        }

        while index < chars.count {
            // Блочный комментарий — до закрывающей пары или конца текста.
            var consumed = false
            for comment in profile.blockComments where matches(comment.open, at: index) {
                flush()
                var end = index + comment.open.count
                while end + comment.close.count <= chars.count, !matches(comment.close, at: end) { end += 1 }
                let closes = matches(comment.close, at: end)
                let stop = closes ? end + comment.close.count : chars.count
                segments.append(Segment(text: String(chars[index..<stop]), kind: .comment))
                index = stop
                consumed = true
                break
            }
            if consumed { continue }

            // Строчный комментарий — до конца строки.
            for prefix in profile.lineComments where matches(Array(prefix), at: index) {
                flush()
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                segments.append(Segment(text: String(chars[index..<end]), kind: .comment))
                index = end
                consumed = true
                break
            }
            if consumed { continue }

            let char = chars[index]

            // Тройные кавычки (python) — многострочные.
            if profile.tripleQuotes, char == "\"", matches(["\"", "\"", "\""], at: index) {
                flush()
                var end = index + 3
                while end + 3 <= chars.count, !matches(["\"", "\"", "\""], at: end) { end += 1 }
                let stop = end + 3 <= chars.count ? end + 3 : chars.count
                segments.append(Segment(text: String(chars[index..<stop]), kind: .string))
                index = stop
                continue
            }
            if profile.tripleQuotes, char == "'", matches(["'", "'", "'"], at: index) {
                flush()
                var end = index + 3
                while end + 3 <= chars.count, !matches(["'", "'", "'"], at: end) { end += 1 }
                let stop = end + 3 <= chars.count ? end + 3 : chars.count
                segments.append(Segment(text: String(chars[index..<stop]), kind: .string))
                index = stop
                continue
            }

            // Простые кавычки — до пары; экранирование учитывается, перенос строки
            // закрывает строку (многострочные дают только тройные кавычки и backtick).
            if profile.quoted.contains(char) {
                flush()
                var end = index + 1
                while end < chars.count {
                    if chars[end] == "\n" { break }
                    if chars[end] == "\\" {
                        end += 2
                        continue
                    }
                    if chars[end] == char { end += 1; break }
                    end += 1
                }
                let stop = min(end, chars.count)
                segments.append(Segment(text: String(chars[index..<stop]), kind: .string))
                index = stop
                continue
            }

            // Backtick-строки (js, go, bash) — многострочные.
            if profile.backtick, char == "`" {
                flush()
                var end = index + 1
                while end < chars.count, chars[end] != "`" {
                    if profile.backtickEscapes, chars[end] == "\\" { end += 1 }
                    guard end < chars.count else { break }
                    end += 1
                }
                let stop = end < chars.count ? end + 1 : chars.count
                segments.append(Segment(text: String(chars[index..<stop]), kind: .string))
                index = stop
                continue
            }

            // Числа: цифра и хвост из алфавита литералов (hex, точки, суффиксы).
            if (char.isNumber && char.isASCII) || (char == "." && index + 1 < chars.count
                                                   && chars[index + 1].isNumber && chars[index + 1].isASCII) {
                flush()
                var end = index + 1
                while end < chars.count {
                    let c = chars[end]
                    let asciiLetter = c.isLetter && c.isASCII
                    if !(asciiLetter || (c.isNumber && c.isASCII) || c == "." || c == "_") { break }
                    end += 1
                }
                segments.append(Segment(text: String(chars[index..<end]), kind: .number))
                index = end
                continue
            }

            // Идентификаторы и ключевые слова.
            if isIdentifierStart(char) {
                var end = index + 1
                while end < chars.count, isIdentifierPart(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                let key = profile.caseInsensitiveKeywords ? word.lowercased() : word
                if profile.keywords.contains(key) {
                    flush()
                    segments.append(Segment(text: word, kind: .keyword))
                } else {
                    plain += word
                }
                index = end
                continue
            }

            plain.append(char)
            index += 1
        }
        flush()
        return segments
    }

    // MARK: - Языковые профили

    private struct Profile {
        let keywords: Set<String>
        let lineComments: [String]
        /// Пары (открывающая, закрывающая) последовательности.
        let blockComments: [(open: [Character], close: [Character])]
        let quoted: [Character]
        let tripleQuotes: Bool
        let backtick: Bool
        let backtickEscapes: Bool
        let caseInsensitiveKeywords: Bool
    }

    private static func profile(
        keywords: [String], lineComments: [String] = [], blockComments: [(String, String)] = [],
        quoted: [Character] = ["\"", "'"], tripleQuotes: Bool = false,
        backtick: Bool = false, backtickEscapes: Bool = true, caseInsensitive: Bool = false
    ) -> Profile {
        Profile(keywords: Set(keywords), lineComments: lineComments,
                blockComments: blockComments.map { (Array($0.0), Array($0.1)) },
                quoted: quoted, tripleQuotes: tripleQuotes, backtick: backtick,
                backtickEscapes: backtickEscapes, caseInsensitiveKeywords: caseInsensitive)
    }

    private static let profiles: [String: Profile] = {
        var map: [String: Profile] = [:]
        map["python"] = profile(
            keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield True False None"),
            lineComments: ["#"], tripleQuotes: true)
        map["py"] = map["python"]!
        map["bash"] = profile(
            keywords: words("if then else elif fi for while until do done case esac function return select coproc time in"),
            lineComments: ["#"], backtick: true)
        for alias in ["sh", "shell", "zsh"] where map[alias] == nil { map[alias] = map["bash"]! }
        map["javascript"] = profile(
            keywords: words("async await break case catch class const continue default delete do else export extends finally for function if import in instanceof let new of return static switch this throw try typeof var void while yield true false null undefined"),
            lineComments: ["//"], blockComments: [("/*", "*/")],
            backtick: true)
        for alias in ["js", "ts", "typescript", "jsx", "tsx"] where map[alias] == nil {
            map[alias] = map["javascript"]!
        }
        map["json"] = profile(keywords: ["true", "false", "null"])
        map["go"] = profile(
            keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false"),
            lineComments: ["//"], blockComments: [("/*", "*/")],
            backtick: true, backtickEscapes: false)
        map["golang"] = map["go"]!
        map["sql"] = profile(
            keywords: words("and as asc between by case create cross default delete desc distinct drop else end exists from full group having in index inner insert into is join left like limit not null offset on or order outer primary references right select set table then union update values when where with true false"),
            lineComments: ["--"], blockComments: [("/*", "*/")],
            quoted: ["'"], caseInsensitive: true)
        for alias in ["psql", "postgres"] where map[alias] == nil { map[alias] = map["sql"]! }
        return map
    }()

    private static func words(_ spaceSeparated: String) -> [String] {
        spaceSeparated.split(separator: " ").map(String.init)
    }
}
