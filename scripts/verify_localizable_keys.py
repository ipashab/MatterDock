#!/usr/bin/env python3
"""Верификация ключей `String(localized:)` живой компиляцией.

Строит probe-файл с теми же интерполяциями (типовые заглушки вместо реальных
выражений), запускает его swift-интерпретатором: без записей в каталоге
`String(localized:)` возвращает сам сгенерированный компилятором ключ.
Сверяет его с рендером экстрактора (scripts/extract_localizable_keys.py):
так проверяются типы плейсхолдеров (%lld/%@) и экранирование '%'.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

T = Path("/var/folders/28/cn5rsh4n7xj0h0xq0b8lf7fh0000gp/T/opencode")

# Выражения, чья интерполяция идёт как %@; всё остальное — числовое (%lld).
STRING_EXPR = re.compile(
    r"String\(|ByteCountFormatter|fullDateTime|describe\(|endpoint\.description"
    r"|attachment\.name|alert\.channelName|alert\.senderName|header\.displayName"
    r"|session\.slot\.user\.username|names\[|configuration\.currentLabel"
    r"|^(team|name|title|site|head|origin|siteName|emoji|what|shortcut|authorName|displayName|time|amount|size)$"
)

# Поеханные правила типизации, выверенные по исходникам (см. render_key):
# одноимённые выражения в разных строках бывают разных типов (например,
# `status` — Int в UserFacingErrorText и String в ComposerAttachmentStrip),
# поэтому правятся по-ключево.
RENDER_OVERRIDES: dict[str, str] = {
    "Command reply: %lld": "Command reply: %@",
    "Default (%lld)": "Default (%@)",
    "Do Not Disturb until %lld": "Do Not Disturb until %@",
    "Until %lld": "Until %@",
    "Mattermost %lld": "Mattermost %@",
    "Mattermost %lld — not a release line MatterMac has been tested with.":
        "Mattermost %@ — not a release line MatterMac has been tested with.",
    "Separate keywords with commas. @%lld always mentions you. Matching ignores case.":
        "Separate keywords with commas. @%@ always mentions you. Matching ignores case.",
    "Step %lld of %lld: %lld": "Step %lld of %lld: %@",
    "%@, signed in as %lld": "%@, signed in as %@",
    "%lld, channels and messages": "%@, channels and messages",
    "Remove %lld": "Remove %@",
    "Add Members to %lld": "Add Members to %@",
    "%@, %@, %lld": "%@, %@, %@",
    # рассыпавшиеся интерполяции со скобками/замыканиями внутри
    "Signed in to %lld.formatted(.list(type: .and))}": "Signed in to %@",
    "Version %lld (%lld": "Version %@ (%@)",
    "%lld — browse or create channels and messages": "%@ — browse or create channels and messages",
}

def placeholder(expr: str) -> str:
    inner = expr.strip()
    m = re.match(r"^String\((.*)\)$", inner)
    if m:
        inner = m.group(1).strip()
    return "%@" if (STRING_EXPR.search(inner) or STRING_EXPR.search(expr.strip())) else "%lld"

def render_key(content: str) -> str:
    """INTERP{expr} -> плейсхолдер; '%' в строке с плейсхолдером -> '%%'."""
    pieces = []
    i = 0
    has_placeholder = False
    while i < len(content):
        if content.startswith("INTERP{", i):
            end = content.index("}", i)
            pieces.append(placeholder(content[i + 7:end]))
            has_placeholder = True
            i = end + 1
        else:
            j = i
            while j < len(content) and not content.startswith("INTERP{", j):
                j += 1
            pieces.append(content[i:j])
            i = j
    rendered = "".join(pieces)
    # замена один раз: сначала помечаем плейсхолдеры, потом удваиваем '%'
    if has_placeholder:
        rendered = rendered.replace("%lld", "\x00lld").replace("%@", "\x00@")
        rendered = rendered.replace("%", "%%")
        rendered = rendered.replace("\x00lld", "%lld").replace("\x00@", "%@")
    return RENDER_OVERRIDES.get(rendered, rendered)

def probe_line(idx: int, content: str) -> str:
    """Swift-строка: заглушки правильных типов + тот же литерал."""
    decls = []
    literal = []
    ti = 0
    i = 0
    while i < len(content):
        if content.startswith("INTERP{", i):
            end = content.index("}", i)
            ph = placeholder(content[i + 7:end])
            name = f"v{idx}_{ti}"
            stub = '"0"' if ph == "%@" else "3"
            decls.append(f'let {name}: {"String" if ph == "%@" else "Int"} = {stub}')
            literal.append(f"\\({name})")
            ti += 1
            i = end + 1
        else:
            j = i
            while j < len(content) and not content.startswith("INTERP{", j):
                j += 1
            literal.append(content[i:j].replace("\\", "\\\\").replace('"', '\\"'))
            i = j
    body = f'print(String(localized: "{"".join(literal)}"))'
    if decls:
        return "do { " + "; ".join(decls) + "; " + body + " }"
    return body

def main():
    keys = json.load(open(T / "keys.json"))
    interp = [k for k in keys if "INTERP{" in k]
    probe = T / "probe_keys.swift"
    probe.write_text("import Foundation\n" + "\n".join(probe_line(i, c) for i, c in enumerate(interp)))
    result = subprocess.run(
        ["xcrun", "swift", str(probe)],
        capture_output=True, text=True,
        env={"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "PATH": "/usr/bin:/bin:/usr/local/bin"},
        timeout=300,
    )
    if result.returncode != 0:
        print("probe failed:", result.stderr[:2000])
        return 1
    got = result.stdout.splitlines()
    if len(got) != len(interp):
        print(f"строк: got {len(got)}, expected {len(interp)}")
        return 1
    failures = 0
    for expected, actual in zip((render_key(c) for c in interp), got):
        if expected != actual:
            failures += 1
            print("MISMATCH\n  expected:", repr(expected), "\n  compiler:", repr(actual))
    print("OK: все ключи совпали" if failures == 0 else f"{failures} расхождений")
    return 0 if failures == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
