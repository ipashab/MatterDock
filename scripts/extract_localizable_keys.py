#!/usr/bin/env python3
"""Извлечение ключей String(localized:) из исходников MatterDock.

Плоские литералы идут как есть; интерполированные помечаются INTERP{…}
для ручного вывода плейсхолдера (тип виден только из контекста компилятора;
итоговые ключи сверяются живым probe-тестом в том же каталоге).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def parse_swift_string(source: str, start: int):
    """Разбирает Swift-строковый литерал от открывающей кавычки.
    Возвращает (содержимое, конец)."""
    if source.startswith('"""', start):
        content_end = source.find('"""', start + 3)
        return source[start + 3:content_end], content_end + 3
    j = start + 1
    while j < len(source):
        if source[j] == "\\":
            j += 2
            continue
        if source[j] == '"':
            break
        j += 1
    return source[start + 1:j], j + 1

def render(content: str):
    """Рендерит содержимое литерала: чистые сегменты как есть (учёт escape),
    интерполяции -> INTERP{выражение} для ручного вывода типа."""
    out = []
    i = 0
    has_interp = False
    while i < len(content):
        ch = content[i]
        if ch == "\\":
            nxt = content[i + 1]
            if nxt == "(":
                depth = 1
                j = i + 2
                while j < len(content) and depth:
                    if content[j] == "(":
                        depth += 1
                    elif content[j] == ")":
                        depth -= 1
                    j += 1
                out.append("INTERP{" + content[i + 2:j - 1].strip() + "}")
                has_interp = True
                i = j
                continue
            escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            out.append(escapes.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out), has_interp

def extract(source: str):
    results = []
    markers = ("String(localized:", "Text(", "Picker(", "Button(", "Toggle(",
               "TextField(", "SecureField(", "LabeledContent(", "Label(",
               "GroupBox(", "navigationTitle(", "Window(")
    pos = 0
    while True:
        found, marker = -1, None
        for m in markers:
            p = source.find(m, pos)
            if p >= 0 and (found < 0 or p < found):
                found, marker = p, m
        if found < 0:
            break
        j = found + len(marker)
        while j < len(source) and source[j] in " \t\n\r":
            j += 1
        if j < len(source) and source[j] in '"':
            content, end = parse_swift_string(source, j)
            key, has_interp = render(content)
            results.append((key, has_interp, found))
            pos = end
        else:
            pos = found + len(marker)
    return results

def main():
    files = sorted((ROOT / "Packages" / "MatterMacKit" / "Sources").rglob("*.swift"))
    app_src = ROOT / "Apps" / "MatterMac" / "Sources"
    if app_src.exists():
        files += sorted(app_src.rglob("*.swift"))
    keys = {}
    ref = "#REF"  # файл:смещение для ручного поиска контекста
    for path in files:
        text = path.read_text()
        rel = str(path.relative_to(ROOT))
        for key, has_interp, offset in extract(text):
            entry = keys.setdefault(key, {"count": 0, "interpolated": has_interp})
            entry["count"] += 1
            entry.setdefault("refs", []).append(f"{rel}:{offset}")
    print(json.dumps(keys, ensure_ascii=False, indent=1))

if __name__ == "__main__":
    sys.exit(main())
