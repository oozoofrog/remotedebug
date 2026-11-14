#!/usr/bin/env python3
"""Find Korean string literals in Swift sources that the localization extraction did not pick up.

Usage:
    python3 -I scripts/audit_strings.py --stringsdata-root DIR [--stringsdata-root DIR ...]
                                        [--skip REGEX ...] PATH [PATH ...]

The keys come from the *.stringsdata files that the Swift compiler writes when a build runs with
SWIFT_EMIT_LOC_STRINGS=YES (xcodebuild applies it to local package targets too). A missing root is
ignored. Each PATH is a Swift file or a folder scanned for *.swift; folders named Tests (or ending
in Tests), Preview and rdvalidate are skipped, as are comments and `#Preview { ... }` blocks.

Every literal that contains Hangul is compared with the extracted keys after `\\(...)` in the literal
and printf specifiers (%@, %lld, %1$@, ...) in the keys are replaced by the same wildcard. Literals
on lines that look like logging, or that match a --skip regex, are not reported.

Output: one line per unmatched literal, `path:line: "literal"`, then `residual: N  extracted keys: M`.
Exit status: 0 normally, 2 when no key was extracted or on a usage error.
"""

import argparse
import json
import os
import re
import sys

WILDCARD = "\u0000"
HANGUL = re.compile("[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]")
PRINTF = re.compile(r"%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]")
SKIP_DIRS = {"Preview", "rdvalidate", ".build", "Build"}
LOG_PATTERNS = [
    r"\b(?:log|logger|Logger|os_log|NSLog|print|debugPrint|onLog|fatalError|preconditionFailure|precondition|assert|assertionFailure)\s*\(",
    r"\b(?:log|logger|self\.logger|self\.log)\.(?:log|debug|info|notice|warning|error|fault|trace|critical)\s*\(",
]


def load_keys(roots):
    keys = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for folder, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".stringsdata"):
                    continue
                try:
                    with open(os.path.join(folder, name), encoding="utf-8") as handle:
                        data = json.load(handle)
                except (OSError, ValueError):
                    continue
                for entries in (data.get("tables") or {}).values():
                    for entry in entries:
                        key = entry.get("key")
                        if isinstance(key, str):
                            keys.add(key)
    return keys


def normalize_key(key):
    parts = key.split("%%")
    return "%".join(PRINTF.sub(WILDCARD, part) for part in parts)


def preview_lines(source):
    """Line numbers inside `#Preview { ... }` blocks (preview-only code)."""
    lines = set()
    for match in re.finditer(r"#Preview\b", source):
        start = source.find("{", match.end())
        if start < 0:
            continue
        depth, i, quote = 0, start, False
        while i < len(source):
            c = source[i]
            if c == '"' and source[i - 1] != "\\":
                quote = not quote
            elif not quote and c == "{":
                depth += 1
            elif not quote and c == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        first = source.count("\n", 0, match.start()) + 1
        last = source.count("\n", 0, i) + 1
        lines.update(range(first, last + 1))
    return lines


def swift_files(paths):
    for path in paths:
        if os.path.isfile(path):
            if path.endswith(".swift"):
                yield path
            continue
        for folder, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.endswith("Tests"))
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(folder, name)


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


class Lexer:
    """Small Swift lexer: yields (line, text) for each string literal, interpolations as WILDCARD."""

    def __init__(self, source):
        self.s = source
        self.i = 0
        self.line = 1
        self.found = []

    def peek(self, text):
        return self.s.startswith(text, self.i)

    def advance(self, count=1):
        for _ in range(count):
            if self.i < len(self.s):
                if self.s[self.i] == "\n":
                    self.line += 1
                self.i += 1

    def run(self):
        self.code(stop=None)
        return self.found

    def code(self, stop):
        """Scan code until the unbalanced `stop` character (")" inside an interpolation)."""
        depth = 0
        while self.i < len(self.s):
            c = self.s[self.i]
            if self.peek("//"):
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.advance()
            elif self.peek("/*"):
                self.block_comment()
            elif c == "#" and re.match(r'#+"', self.s[self.i:]):
                hashes = len(re.match(r"#+", self.s[self.i:]).group(0))
                self.advance(hashes)
                self.literal(hashes)
            elif c == '"':
                self.literal(0)
            elif stop and c == "(":
                depth += 1
                self.advance()
            elif stop and c == ")":
                if depth == 0:
                    self.advance()
                    return
                depth -= 1
                self.advance()
            else:
                self.advance()

    def block_comment(self):
        nesting = 0
        while self.i < len(self.s):
            if self.peek("/*"):
                nesting += 1
                self.advance(2)
            elif self.peek("*/"):
                nesting -= 1
                self.advance(2)
                if nesting == 0:
                    return
            else:
                self.advance()

    def literal(self, hashes):
        start_line = self.line
        multi = self.peek('"""')
        quote = '"""' if multi else '"'
        self.advance(len(quote))
        closing = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        out = []
        while self.i < len(self.s):
            if self.peek(closing):
                self.advance(len(closing))
                break
            if not multi and self.s[self.i] == "\n":
                break
            if self.peek(escape):
                self.advance(len(escape))
                c = self.s[self.i] if self.i < len(self.s) else ""
                if c == "(":
                    self.advance()
                    self.code(stop=")")
                    out.append(WILDCARD)
                elif c == "u" and self.s.startswith("{", self.i + 1):
                    end = self.s.find("}", self.i)
                    try:
                        out.append(chr(int(self.s[self.i + 2:end], 16)))
                    except ValueError:
                        pass
                    self.advance(end - self.i + 1)
                elif c == "\n" and multi:
                    self.advance()
                    out.append("\x01")  # line continuation
                elif c in ESCAPES:
                    out.append(ESCAPES[c])
                    self.advance()
                else:
                    self.advance()
                continue
            out.append(self.s[self.i])
            self.advance()
        text = "".join(out)
        if multi:
            text = dedent_multiline(text)
        self.found.append((start_line, text))


def dedent_multiline(text):
    lines = text.split("\n")
    if lines and lines[0].strip() == "":
        lines = lines[1:]
    indent = ""
    if lines and lines[-1].strip() == "":
        indent = lines[-1]
        lines = lines[:-1]
    lines = [line[len(indent):] if line.startswith(indent) else line.lstrip() for line in lines]
    return "\n".join(lines).replace("\x01\n", "")


def main(argv):
    parser = argparse.ArgumentParser(description="List Korean Swift literals missing from extracted localization keys.")
    parser.add_argument("--stringsdata-root", action="append", default=[], metavar="DIR")
    parser.add_argument("--skip", action="append", default=[], metavar="REGEX")
    parser.add_argument("paths", nargs="+", metavar="PATH")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if not args.stringsdata_root:
        print("error: at least one --stringsdata-root is required", file=sys.stderr)
        return 2
    try:
        skips = [re.compile(p) for p in LOG_PATTERNS] + [re.compile(p) for p in args.skip]
    except re.error as error:
        print(f"error: bad --skip regex: {error}", file=sys.stderr)
        return 2

    keys = load_keys(args.stringsdata_root)
    patterns = {normalize_key(k) for k in keys}
    residual = 0
    for path in swift_files(args.paths):
        try:
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        lines = source.split("\n")
        previews = preview_lines(source)
        for line, text in Lexer(source).run():
            if not HANGUL.search(text) or line in previews:
                continue
            if text in patterns or normalize_key(text) in patterns:
                continue
            code_line = lines[line - 1] if line - 1 < len(lines) else ""
            if any(p.search(code_line) for p in skips):
                continue
            residual += 1
            shown = text.replace(WILDCARD, "\\(…)").replace("\n", "\\n")
            print(f'{path}:{line}: "{shown}"')
    print(f"residual: {residual}  extracted keys: {len(keys)}")
    return 2 if not keys else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
