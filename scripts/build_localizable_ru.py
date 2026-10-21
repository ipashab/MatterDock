#!/usr/bin/env python3
"""Сборка `ru`-локализации в Apps/MatterMac/Resources/Localizable.xcstrings.

Вход: переводы (RFC JSON словарь key → ru-строка), таблица плюральных вариаций
(для ключей с %lld: one/few/many/other по правилам CLDR русского языка).
Существующие записи каталога не трогаются; ключ `MatterDock` (shouldTranslate
false) остаётся как есть.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Apps" / "MatterMac" / "Resources" / "Localizable.xcstrings"

def string_unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("translations", type=Path, help="JSON: ключ → ru-строка")
    parser.add_argument("plurals", type=Path, help="JSON: ключ → {one, few, many, other}")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    translations = json.loads(args.translations.read_text())
    plurals = json.loads(args.plurals.read_text())

    catalog = json.loads(CATALOG.read_text())
    strings = catalog.setdefault("strings", {})
    missing_plurals = []
    updated = added = 0
    for key, ru in sorted(translations.items()):
        if key == "MatterDock":
            continue  # имя продукта, не переводится
        entry = strings.get(key)
        if entry is None:
            entry = {}
            strings[key] = entry
            added += 1
        else:
            updated += 1
        localizations = entry.setdefault("localizations", {})
        if key in plurals:
            forms = plurals[key]
            missing = [cat for cat in ("one", "few", "many", "other") if cat not in forms]
            if missing:
                missing_plurals.append((key, missing))
                continue
            localizations["ru"] = {
                "variations": {"plural": {cat: string_unit(forms[cat]) for cat in ("one", "few", "many", "other")}}
            }
        else:
            if "%lld" in key:
                missing_plurals.append((key, ["все формы"]))
                continue
            localizations["ru"] = string_unit(ru)

    if missing_plurals:
        for key, missing in missing_plurals:
            print("нет плюральных форм:", key, missing, file=sys.stderr)
        return 1
    report = f"добавлено {added}, обновлено {updated} ключей ru"
    if args.dry_run:
        print(report + " (dry-run)")
        return 0
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(report)
    return 0

if __name__ == "__main__":
    sys.exit(main())
