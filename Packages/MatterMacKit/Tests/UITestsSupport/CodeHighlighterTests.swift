import AppKit
import Testing
import MatterMacModels
@testable import MatterMacUI

/// Лексер подсветки кода (ADR 0053): сегменты восстанавливают текст один в один,
/// ключевые конструкции известных языков окрашены, незнакомые — нет.
@MainActor
@Suite("Code highlighter")
struct CodeHighlighterTests {
    private func kinds(_ segments: [CodeHighlighter.Segment]) -> String {
        segments.map { segment in
            switch segment.kind {
            case .keyword: "K"
            case .string: "S"
            case .comment: "C"
            case .number: "N"
            case nil: "-"
            }
        }.joined()
    }

    @Test func segmentsAlwaysReassembleTheOriginalText() {
        for (language, code) in [
            ("python", "def f():\n    return \"текст\"  # комментарий\n"),
            ("bash", "if [ -n \"$x\" ]; then echo 'ok'; fi # проверка"),
            ("javascript", "const n = 42; // ответ\n/* блок */\n`шаблон ${n}`"),
            ("json", "{\"ключ\": 12, \"живой\": true, \"пусто\": null}"),
            ("go", "func main() {\n\tx := 0x1F\n\t_ = `сырая строка`\n}"),
            ("sql", "SELECT id FROM users WHERE name = 'иван' -- поиск"),
        ] {
            let segments = CodeHighlighter.segments(code, language: language)
            #expect(!segments.isEmpty)
            #expect(segments.map(\.text).joined() == code)
        }
    }

    @Test func pythonKeywordsStringsAndCommentsGetTheirKinds() {
        let code = "def greet(name):\n    return f\"hi {name}\"  # привет\n"
        let segments = CodeHighlighter.segments(code, language: "python")
        #expect(segments.map(\.text).joined() == code)
        // Первый сегмент — def (ключевое слово), «hi {name}» — строка, «# привет» — комментарий.
        #expect(segments.first?.kind == .keyword)
        #expect(segments.first?.text == "def")
        #expect(segments.contains { $0.kind == .string && $0.text.contains("hi") })
        #expect(segments.contains { $0.kind == .comment && $0.text.contains("привет") })
        // Соседние plain-куски слиты; сегментов меньше, чем символов.
        #expect(segments.allSatisfy { !$0.text.isEmpty })
        let plainRuns = segments.filter { $0.kind == nil }
        #expect(plainRuns.count <= 4)
    }

    @Test func tripleQuotedStringsSpanLinesAndUnknownLanguageStaysPlain() {
        let code = "x = \"\"\"\nстрока\n\"\"\"\n"
        let segments = CodeHighlighter.segments(code, language: "py")
        let strings = segments.filter { $0.kind == .string }
        #expect(strings.count == 1)
        #expect(strings[0].text.contains("\n"))
        // Без метки языка подсветки нет.
        #expect(CodeHighlighter.segments(code, language: nil).isEmpty)
        #expect(CodeHighlighter.segments(code, language: "klingon").isEmpty)
    }

    @Test func javascriptBlocksBackticksAndEscapes() {
        let code = "const re = \"a\\\"b\"; /* мульти\nстрочный */ let t = `x\ny`; // хвост"
        let segments = CodeHighlighter.segments(code, language: "js")
        #expect(segments.map(\.text).joined() == code)
        #expect(segments.contains { $0.kind == .keyword && $0.text == "const" })
        // Блочный комментарий сохраняет перенос строки.
        #expect(segments.contains { $0.kind == .comment && $0.text.contains("\n") })
        // Экранированная кавычка не закрывает строку.
        #expect(segments.contains { $0.kind == .string && $0.text == "\"a\\\"b\"" })
        #expect(segments.contains { $0.kind == .string && $0.text.contains("x\ny") })
        #expect(segments.last?.kind == .comment)
    }

    @Test func jsonNumbersAndLiterals() {
        let code = "{\"n\": 12, \"ok\": true, \"x\": null}"
        let segments = CodeHighlighter.segments(code, language: "json")
        #expect(segments.contains { $0.kind == .string && $0.text.contains("n") })
        #expect(segments.contains { $0.kind == .number && $0.text == "12" })
        #expect(segments.contains { $0.kind == .keyword && $0.text == "true" })
        #expect(segments.contains { $0.kind == .keyword && $0.text == "null" })
    }

    @Test func sqlIsCaseInsensitiveWithDashComments() {
        let code = "select id from users -- выборка"
        let segments = CodeHighlighter.segments(code, language: "SQL")
        #expect(segments.contains { $0.kind == .keyword && $0.text == "select" })
        #expect(segments.contains { $0.kind == .comment && $0.text.contains("выборка") })
    }

    @Test func goRawStringsDoNotHonorBackslashEscapes() {
        let code = "s := `a\\nb`"
        let segments = CodeHighlighter.segments(code, language: "go")
        #expect(segments.map(\.text).joined() == code)
        #expect(segments.contains { $0.kind == .string && $0.text.hasSuffix("b`") })
    }

    @Test func renderedCodeBlockCarriesTokenColors() throws {
        let document = MarkupParser.parse("```python\n# заметка\nvalue = \"hi\"\n```")
        let text = MessageRenderer().render(document)
        var colorCount = 0
        var sawCommentColor = false
        var sawStringColor = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in
            guard let color = attrs[.foregroundColor] as? NSColor else { return }
            if color == TimelinePalette.codeComment { sawCommentColor = true; colorCount += 1 }
            if color == TimelinePalette.codeString { sawStringColor = true; colorCount += 1 }
        }
        #expect(sawCommentColor)
        #expect(sawStringColor)
        #expect(colorCount >= 2)
    }

    @Test func unknownLanguageRendersWithASingleColor() throws {
        let document = MarkupParser.parse("```klingon\nvalue = \"hi\"\n```")
        let text = MessageRenderer().render(document)
        var fontColors = Set<NSColor>()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in
            guard let font = attrs[.font] as? NSFont, font.isFixedPitch,
                  let color = attrs[.foregroundColor] as? NSColor else { return }
            fontColors.insert(color)
        }
        #expect(fontColors.count == 1)
    }
}
