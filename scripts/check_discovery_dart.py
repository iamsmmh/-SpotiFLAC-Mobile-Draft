#!/usr/bin/env python3
"""Lexical sanity checker for the Dart sources touched by the discovery work.

This is NOT a substitute for `dart analyze` — it cannot type-check, resolve
symbols across files, or understand Dart's grammar. What it does catch, cheaply
and reliably, is the class of mistake that stops a file from even parsing:

  * unbalanced (), [], {} (strings, raw strings, interpolation and comments
    are skipped properly, including nested /* */);
  * unterminated string / comment literals;
  * `part` / `import` / `export` directives pointing at files that do not exist;
  * identifiers used in `$`/`${...}` interpolation inside SQL strings that are
    not declared in the same file (catches the `ds_recommendation_cache` typo
    class of bug that a lexical pass can actually see);
  * duplicated top-level declarations inside one file.

Usage:  python3 scripts/check_discovery_dart.py [paths...]
Exit code 0 = clean, 1 = problems found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"

BRACKETS = {")": "(", "]": "[", "}": "{"}
OPENERS = set("([{")


class Problem:
    def __init__(self, path: Path, line: int, message: str) -> None:
        self.path = path
        self.line = line
        self.message = message

    def __str__(self) -> str:
        try:
            rel = self.path.relative_to(REPO)
        except ValueError:
            rel = self.path
        return f"{rel}:{self.line}: {self.message}"


def scan(src: str, path: Path) -> tuple[list[Problem], str]:
    """Walks the source once, stripping comments/strings.

    Returns the problems found plus a "code-only" rendering of the file where
    every string body and comment has been replaced by spaces (newlines kept) so
    later regexes can run over declarations without being confused by literals.
    """
    problems: list[Problem] = []
    stack: list[tuple[str, int]] = []
    out: list[str] = []

    i = 0
    line = 1
    n = len(src)

    def blank(text: str) -> str:
        # Preserve newlines so reported line numbers stay correct.
        return "".join("\n" if ch == "\n" else " " for ch in text)

    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if ch == "\n":
            line += 1
            out.append(ch)
            i += 1
            continue

        # ---- comments -------------------------------------------------
        if ch == "/" and nxt == "/":
            end = src.find("\n", i)
            end = n if end < 0 else end
            out.append(blank(src[i:end]))
            i = end
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            j = i + 2
            while j < n and depth:
                if src[j] == "/" and j + 1 < n and src[j + 1] == "*":
                    depth += 1
                    j += 2
                    continue
                if src[j] == "*" and j + 1 < n and src[j + 1] == "/":
                    depth -= 1
                    j += 2
                    continue
                if src[j] == "\n":
                    line += 1
                j += 1
            if depth:
                problems.append(Problem(path, line, "unterminated /* comment"))
            out.append(blank(src[i:j]))
            i = j
            continue

        # ---- strings --------------------------------------------------
        if ch in ("'", '"'):
            triple = src[i : i + 3] == ch * 3
            quote = ch * 3 if triple else ch
            raw = out and out[-1] == "r"
            j = i + len(quote)
            closed = False
            while j < n:
                c = src[j]
                if c == "\n":
                    line += 1
                    if not triple:
                        break
                if not raw and c == "\\":
                    j += 2
                    continue
                if src.startswith(quote, j):
                    j += len(quote)
                    closed = True
                    break
                j += 1
            if not closed:
                problems.append(
                    Problem(path, line, f"unterminated {quote} string")
                )
            # Keep the literal's delimiters as spaces; interpolation inside a
            # literal is checked separately below.
            out.append(blank(src[i:j]))
            i = j
            continue

        # ---- brackets -------------------------------------------------
        if ch in OPENERS:
            stack.append((ch, line))
        elif ch in BRACKETS:
            if not stack:
                problems.append(Problem(path, line, f"stray '{ch}'"))
            else:
                opener, opener_line = stack.pop()
                if opener != BRACKETS[ch]:
                    problems.append(
                        Problem(
                            path,
                            line,
                            f"'{ch}' closes '{opener}' opened on line {opener_line}",
                        )
                    )
        out.append(ch)
        i += 1

    for opener, opener_line in stack:
        problems.append(
            Problem(path, opener_line, f"unclosed '{opener}'")
        )

    return problems, "".join(out)


DIRECTIVE = re.compile(
    r"^\s*(?:import|export|part)\s+'([^']+)'", re.MULTILINE
)
PACKAGE = "package:spotiflac_android/"


def check_directives(src: str, path: Path) -> list[Problem]:
    problems: list[Problem] = []
    for match in DIRECTIVE.finditer(src):
        target = match.group(1)
        if target.startswith("dart:"):
            continue
        if target.startswith(PACKAGE):
            resolved = LIB / target[len(PACKAGE) :]
        elif target.startswith("package:"):
            continue  # third-party; resolved by pub
        else:
            resolved = (path.parent / target).resolve()
        if not resolved.exists():
            line = src[: match.start()].count("\n") + 1
            problems.append(Problem(path, line, f"missing target '{target}'"))
    return problems


DECL = re.compile(
    r"^(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+|mixin\s+)*"
    r"(?:class|enum|extension|mixin|typedef)\s+([A-Za-z_$][\w$]*)",
    re.MULTILINE,
)
TOP_LEVEL_FN = re.compile(
    r"^(?!//)([A-Za-z_$][\w<>,?\s]*?)\s+([a-z_$][\w$]*)\s*(?:<[^>]*>)?\(",
    re.MULTILINE,
)


def check_duplicates(code: str, path: Path) -> list[Problem]:
    problems: list[Problem] = []
    seen: dict[str, int] = {}
    for match in DECL.finditer(code):
        name = match.group(1)
        line = code[: match.start()].count("\n") + 1
        if name in seen:
            problems.append(
                Problem(
                    path,
                    line,
                    f"'{name}' declared twice (first on line {seen[name]})",
                )
            )
        else:
            seen[name] = line
    return problems


INTERPOLATION = re.compile(r"\$\{?\s*([A-Za-z_$][\w$]*)")
CONST_DECL = re.compile(r"^const\s+String\s+([A-Za-z_$][\w$]*)", re.MULTILINE)
LOCAL_DECL = re.compile(
    r"(?:for\s*\(\s*(?:final|var)\s+|\b(?:final|var)\s+)"
    r"([A-Za-z_$][\w$]*)\s*(?:\s*=|\s+in\b)",
)


def check_sql_interpolation(src: str, path: Path) -> list[Problem]:
    """Finds `$name` inside SQL-looking literals that no local const declares.

    The discovery schema builds every statement by interpolating table-name
    constants; a typo there is invisible until the migration runs on a device.
    """
    problems: list[Problem] = []
    declared = set(CONST_DECL.findall(src))
    # Loop variables and local `final`s are legitimate interpolation targets
    # (tests build table names in a `for` loop over the schema constants).
    declared |= set(LOCAL_DECL.findall(src))
    # Only look at multi-line (''' ... ''') blocks, which is where SQL lives.
    for match in re.finditer(r"'''(.*?)'''", src, re.DOTALL):
        body = match.group(1)
        if "CREATE TABLE" not in body and "CREATE INDEX" not in body:
            continue
        for ident in INTERPOLATION.findall(body):
            if ident not in declared:
                line = src[: match.start()].count("\n") + body[
                    : body.find("$" + ident)
                ].count("\n") + 1
                problems.append(
                    Problem(
                        path,
                        line,
                        f"SQL interpolates '${ident}' which no const in this "
                        "file declares",
                    )
                )
    # Single-quoted index statements as well.
    for match in re.finditer(r"'(CREATE (?:INDEX|TABLE)[^']*)'", src):
        body = match.group(1)
        for ident in INTERPOLATION.findall(body):
            if ident not in declared:
                line = src[: match.start()].count("\n") + 1
                problems.append(
                    Problem(
                        path,
                        line,
                        f"SQL interpolates '${ident}' which no const in this "
                        "file declares",
                    )
                )
    return problems


def check_file(path: Path) -> list[Problem]:
    src = path.read_text(encoding="utf-8")
    problems, code = scan(src, path)
    problems += check_directives(src, path)
    problems += check_duplicates(code, path)
    problems += check_sql_interpolation(src, path)
    return problems


def collect(args: list[str]) -> list[Path]:
    if args:
        return [Path(a) for a in args]
    return sorted(
        list((LIB / "engine" / "discovery").glob("*.dart"))
        + list((LIB / "ecosystem" / "discovery").glob("*.dart"))
        + list((LIB / "screens" / "discovery").glob("*.dart"))
        + [
            LIB / "ecosystem" / "ecosystem.dart",
            LIB / "ecosystem" / "ecosystem_database.dart",
            LIB / "providers" / "discovery_providers.dart",
            LIB / "providers" / "playback_statistics_provider.dart",
            LIB / "screens" / "for_you_screen.dart",
            LIB / "l10n" / "staged_strings.dart",
            LIB / "main.dart",
        ]
    )


def main(argv: list[str]) -> int:
    paths = [p for p in collect(argv[1:]) if p.exists()]
    missing = [p for p in collect(argv[1:]) if not p.exists()]
    total = 0
    for path in paths:
        problems = check_file(path)
        for problem in problems:
            print(problem)
        total += len(problems)
    for path in missing:
        print(f"{path}: file not found")
        total += 1
    checked = len(paths)
    if total == 0:
        print(f"lexical check: {checked} files, 0 problems")
        return 0
    print(f"lexical check: {checked} files, {total} problems")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
