#!/usr/bin/env python3
"""Check that every localizable string has a translation in every shipped language.

Usage:
    python3 -I scripts/check_strings.py [--catalog PATH ...] [--web PATH | --no-web]

Defaults: every Localization/**/*.xcstrings of the repository and the translation table of the install
web page (core/internal/host/web/logic.js, between the lines `// RD-STRINGS-BEGIN` and
`// RD-STRINGS-END`; the text from the first `{` to the last `}` there is JSON).

String catalogs (.xcstrings, source language ko): every key needs a non-empty value in en, ja, zh-Hans
and zh-Hant, in a stringUnit or in every leaf of its variations (plural, device). A key with
"shouldTranslate": false is exempt. The printf specifiers of each value must match those of the source
text (the ko value when present, otherwise the key): same argument types at the same argument positions,
so `%1$@ %2$lld` may be reordered as `%2$lld %1$@`; `%%` is ignored. A plural variant other than
"other" may leave out an argument. Values with substitutions (%#@name@) are checked for presence only.

Web table: the four language objects must hold the same keys; a value "" is not translated yet, and
a translation must use the same {placeholder} names as its key.

Output: one line per problem, `file: key: language: reason`, then a summary with the missing count per
language. Exit status: 0 when complete, 1 when a translation is missing or does not match its source,
2 on a usage, read or parse error.
"""

import argparse
import glob
import json
import os
import re
import sys

LANGUAGES = ["en", "ja", "zh-Hans", "zh-Hant"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WEB = os.path.join("core", "internal", "host", "web", "logic.js")
PRINTF = re.compile(
    r"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])"
)
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")


class InputError(Exception):
    pass


def specifiers(text):
    """Map argument position -> type (length + conversion) for the printf specifiers in text."""
    text = text.replace("%%", "")
    text = re.sub(r"%#@[A-Za-z0-9_]+@", "", text)
    result = {}
    sequential = 0
    for match in PRINTF.finditer(text):
        position, length, conversion = match.groups()
        if position:
            index = int(position)
        else:
            sequential += 1
            index = sequential
        kind = (length or "") + conversion
        if kind in ("d", "i", "D"):
            kind = "d"
        result[index] = kind
    return result


def describe(spec):
    return " ".join("%d:%%%s" % (index, kind) for index, kind in sorted(spec.items())) or "none"


def leaves(localization, path=""):
    """Yield (variant path, stringUnit dict or None) for every leaf of a localization."""
    if "stringUnit" in localization:
        yield path, localization["stringUnit"]
    variations = localization.get("variations")
    if isinstance(variations, dict):
        for kind, cases in variations.items():
            if not isinstance(cases, dict):
                continue
            for case, child in cases.items():
                if isinstance(child, dict):
                    yield from leaves(child, "%s%s.%s/" % (path, kind, case))
    if "stringUnit" not in localization and not isinstance(variations, dict):
        yield path, None


def check_catalog(path, problems, missing):
    try:
        with open(path, encoding="utf-8") as handle:
            catalog = json.load(handle)
    except OSError as error:
        raise InputError("%s: cannot read: %s" % (path, error.strerror or error))
    except ValueError as error:
        raise InputError("%s: not valid JSON: %s" % (path, error))
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise InputError("%s: no \"strings\" object" % path)
    if catalog.get("sourceLanguage") != "ko":
        problems.append("%s: -: -: sourceLanguage is %r, expected ko" % (path, catalog.get("sourceLanguage")))
    checked = 0
    for key in sorted(strings):
        entry = strings[key] or {}
        if entry.get("shouldTranslate") is False:
            continue
        checked += 1
        localizations = entry.get("localizations") or {}
        source = key
        ko = localizations.get("ko") or {}
        if isinstance(ko.get("stringUnit"), dict) and ko["stringUnit"].get("value"):
            source = ko["stringUnit"]["value"]
        source_spec = specifiers(source)
        label = json.dumps(key, ensure_ascii=False)
        for language in LANGUAGES:
            localization = localizations.get(language)
            if not localization:
                problems.append("%s: %s: %s: missing" % (path, label, language))
                missing[language] += 1
                continue
            has_substitutions = bool(localization.get("substitutions"))
            reported_missing = False
            for variant, unit in leaves(localization):
                where = " (%s)" % variant.rstrip("/") if variant else ""
                value = (unit or {}).get("value") or ""
                state = (unit or {}).get("state")
                if not value or state == "new":
                    problems.append("%s: %s: %s: missing%s" % (path, label, language, where))
                    if not reported_missing:
                        missing[language] += 1
                        reported_missing = True
                    continue
                if has_substitutions or "%#@" in value:
                    continue
                spec = specifiers(value)
                optional = variant.startswith("plural.") and not variant.startswith("plural.other/")
                if optional:
                    bad = any(source_spec.get(index) != kind for index, kind in spec.items())
                else:
                    bad = spec != source_spec
                if bad:
                    problems.append("%s: %s: %s: format specifiers %s differ from the source %s%s" % (
                        path, label, language, describe(spec), describe(source_spec), where))
    return checked


def check_web(path, problems, missing):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise InputError("%s: cannot read: %s" % (path, error.strerror or error))
    begin = text.find("// RD-STRINGS-BEGIN")
    end = text.find("// RD-STRINGS-END")
    if begin < 0 or end < begin:
        raise InputError("%s: no // RD-STRINGS-BEGIN ... // RD-STRINGS-END block" % path)
    block = text[begin:end]
    first, last = block.find("{"), block.rfind("}")
    if first < 0 or last < first:
        raise InputError("%s: no JSON object in the RD-STRINGS block" % path)
    try:
        table = json.loads(block[first:last + 1])
    except ValueError as error:
        raise InputError("%s: the RD-STRINGS block is not valid JSON: %s" % (path, error))
    if not isinstance(table, dict):
        raise InputError("%s: the RD-STRINGS block is not a JSON object" % path)
    keys = set()
    for language in LANGUAGES:
        values = table.get(language)
        if not isinstance(values, dict):
            raise InputError("%s: the RD-STRINGS block has no %r object" % (path, language))
        keys.update(values)
    for key in sorted(keys):
        label = json.dumps(key, ensure_ascii=False)
        expected = set(PLACEHOLDER.findall(key))
        for language in LANGUAGES:
            values = table[language]
            if key not in values:
                problems.append("%s: %s: %s: key missing from this language's object" % (path, label, language))
                missing[language] += 1
                continue
            value = values[key]
            if not isinstance(value, str):
                problems.append("%s: %s: %s: value is not a string" % (path, label, language))
                continue
            if value == "":
                problems.append("%s: %s: %s: missing" % (path, label, language))
                missing[language] += 1
                continue
            found = set(PLACEHOLDER.findall(value))
            if found != expected:
                problems.append("%s: %s: %s: placeholders {%s} differ from the source {%s}" % (
                    path, label, language, ", ".join(sorted(found)), ", ".join(sorted(expected))))
    return len(keys)


def main(argv):
    parser = argparse.ArgumentParser(description="Check translations of the string catalogs and the web page table.")
    parser.add_argument("--catalog", action="append", metavar="PATH",
                        help="a .xcstrings file (repeatable; default: Localization/**/*.xcstrings)")
    web = parser.add_mutually_exclusive_group()
    web.add_argument("--web", metavar="PATH", help="the web page script with the RD-STRINGS table (default: %s)" % DEFAULT_WEB)
    web.add_argument("--no-web", action="store_true", help="do not check the web page table")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 2 if exit_.code else 0

    catalogs = args.catalog
    if not catalogs:
        catalogs = sorted(glob.glob(os.path.join(ROOT, "Localization", "**", "*.xcstrings"), recursive=True))
        if not catalogs:
            print("check_strings: no .xcstrings under Localization/", file=sys.stderr)
            return 2
    web_path = None if args.no_web else (args.web or os.path.join(ROOT, DEFAULT_WEB))

    problems = []
    missing = {language: 0 for language in LANGUAGES}
    counted = []
    try:
        for path in catalogs:
            counted.append((path, check_catalog(path, problems, missing)))
        if web_path:
            counted.append((web_path, check_web(web_path, problems, missing)))
    except InputError as error:
        print("check_strings: %s" % error, file=sys.stderr)
        return 2

    for line in problems:
        print(line.replace(ROOT + os.sep, ""))
    total = sum(count for _, count in counted)
    print("checked %d keys in %d files; problems: %d; missing per language: %s" % (
        total, len(counted), len(problems), ", ".join("%s %d" % item for item in missing.items())))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
