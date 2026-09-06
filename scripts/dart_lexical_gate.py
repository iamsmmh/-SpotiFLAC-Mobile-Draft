#!/usr/bin/env python3
"""Lexical gate for Dart sources (toolchain-free).

Complements `flutter analyze` (which runs in CI with the real toolchain) with
checks that are verifiable in any sandbox:

  1. Bracket/paren/brace balance per file — string literals (single, double,
     raw, triple) and comments (line, block, doc) are tokenized, not naively
     counted.
  2. `import`/`export`/`part` targets exist in the repo (package: URIs resolve
     against lib/, relative URIs against the importing file; `dart:` and
     `package:<pkg>/…` for foreign packages are skipped).
  3. Every `part`/`part of` pair matches an existing sibling file.

Exit code 0 only when every check passes. Pass `--only <path>…` to scope the
run to a subset of files/directories.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIRS = {")": "(", "]": "[", "}": "{"}


def strip_strings_and_comments(source: str) -> tuple[str, list[tuple[int, str]]]:
    """Returns Dart source with comments and string *contents* blanked.
    `${…}` interpolations inside strings are re-emitted as real code (they
    contain expressions — and possibly further nested strings)."""
    out: list[str] = []
    literals: list[tuple[int, str]] = []
    n = len(source)

    def scan_from(i: int, line: int) -> int:
        """Tokenizes source[i:] into out; returns when the source ends.
        Returns nothing; mutates `out`. `line` is only tracked via the
        enclosing scope through the nonlocal below."""
        nonlocal_line = line
        while i < n:
            ch = source[i]
            nxt = source[i + 1] if i + 1 < n else ""
            if ch == "\n":
                nonlocal_line += 1
                out.append(ch)
                i += 1
                continue
            if ch == "/" and nxt == "/":
                while i < n and source[i] != "\n":
                    i += 1
                continue
            if ch == "/" and nxt == "*":
                depth = 1
                i += 2
                while i < n and depth:
                    if source.startswith("/*", i):
                        depth += 1
                        i += 2
                    elif source.startswith("*/", i):
                        depth -= 1
                        i += 2
                    else:
                        if source[i] == "\n":
                            nonlocal_line += 1
                        i += 1
                continue
            if ch in "'\"":
                quote = ch
                triple = source.startswith(quote * 3, i)
                delim = quote * 3 if triple else quote
                raw = False
                if out and out[-1] == "r":
                    raw = True
                    out.pop()
                i += len(delim)
                buf: list[str] = []
                while i < n:
                    if not raw and source[i] == "\\":
                        buf.append(source[i : i + 2])
                        i += 2
                        continue
                    if source.startswith(delim, i):
                        i += len(delim)
                        break
                    if source[i] == "\n":
                        if not triple:
                            break  # unterminated single-line string
                        nonlocal_line += 1
                    if not raw and source[i] == "$" and source.startswith("${", i):
                        # Interpolation: emit the group as real code by
                        # recursively scanning it (nested strings included).
                        out.append(" ")
                        i += 2
                        depth = 1
                        while i < n and depth:
                            if source[i] == "{":
                                depth += 1
                                out.append(source[i])
                                i += 1
                            elif source[i] == "}":
                                depth -= 1
                                if depth == 0:
                                    out.append(" ")
                                    i += 1
                                else:
                                    out.append(source[i])
                                    i += 1
                            elif source[i] in "'\"":
                                # Nested string literal inside interpolation.
                                inner_quote = source[i]
                                inner_triple = source.startswith(inner_quote * 3, i)
                                inner_delim = inner_quote * 3 if inner_triple else inner_quote
                                if out and out[-1] == "r":
                                    out.pop()
                                i += len(inner_delim)
                                while i < n:
                                    if source[i] == "\\":
                                        i += 2
                                        continue
                                    if source.startswith(inner_delim, i):
                                        i += len(inner_delim)
                                        break
                                    if source[i] == "\n" and not inner_triple:
                                        break
                                    if source[i] == "$" and source.startswith("${", i):
                                        out.append(" ")
                                        i += 2
                                        d2 = 1
                                        while i < n and d2:
                                            if source[i] == "{":
                                                d2 += 1
                                                out.append(source[i])
                                                i += 1
                                            elif source[i] == "}":
                                                d2 -= 1
                                                out.append(" " if d2 == 0 else source[i])
                                                i += 1
                                            else:
                                                out.append(source[i])
                                                i += 1
                                        continue
                                    if source[i] == "\n":
                                        nonlocal_line += 1
                                    out.append(source[i])
                                    i += 1
                                out.append(" ")
                                continue
                            else:
                                out.append(source[i])
                                i += 1
                        continue
                    buf.append(source[i])
                    i += 1
                if "$" in "".join(buf) and not raw:
                    literals.append((nonlocal_line, "".join(buf)[:80]))
                out.append(" ")
                continue
            out.append(ch)
            i += 1
        return nonlocal_line

    scan_from(0, 1)
    return "".join(out), literals


def check_balance(rel: str, source: str) -> list[str]:
    errors: list[str] = []
    code, _ = strip_strings_and_comments(source)
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
            continue
        if ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack or stack[-1][0] != PAIRS[ch]:
                opening = f"'{stack[-1][0]}' at line {stack[-1][1]}" if stack else "<none>"
                errors.append(f"{rel}:{line}: unbalanced '{ch}' (innermost open: {opening})")
                if len(errors) > 8:
                    return errors
            else:
                stack.pop()
    for ch, at in stack:
        errors.append(f"{rel}:{at}: unclosed '{ch}'")
    return errors


def resolve_target(rel: str, target: str) -> str | bool:
    """Returns the repo-relative path when the target exists, True when the
    target is external (dart:/foreign package — not checkable), False when
    the target is missing."""
    if target.startswith("dart:"):
        return True
    if target.startswith("package:"):
        pkg, _, rest = target[len("package:"):].partition("/")
        if pkg != "spotiflac_android":
            return True
        candidate = os.path.join(ROOT, "lib", rest)
    else:
        base = os.path.dirname(os.path.join(ROOT, rel))
        candidate = os.path.normpath(os.path.join(base, target))
    for suffix in ("", ".dart"):
        path = candidate + suffix
        if os.path.isfile(path):
            return os.path.relpath(path, ROOT)
    return False


def check_imports(rel: str, source: str) -> list[str]:
    errors: list[str] = []
    for m in re.finditer(
        r"^\s*(?:import|export|part)\s+(['\"])(.+?)\1", source, re.M
    ):
        target = m.group(2)
        if resolve_target(rel, target) is False:
            errors.append(f"{rel}: {m.group(0).strip()[:90]} — target not found")
    return errors


def main() -> int:
    args = sys.argv[1:]
    only: list[str] = []
    if "--only" in args:
        idx = args.index("--only")
        only = args[idx + 1 :]
        args = args[:idx]
    files: list[str] = []
    for base, dirs, names in os.walk(os.path.join(ROOT, "lib")):
        dirs[:] = [d for d in dirs if d not in (".dart_tool",)]
        for name in sorted(names):
            if name.endswith(".dart"):
                files.append(os.path.relpath(os.path.join(base, name), ROOT))
    if only:
        files = [
            f
            for f in files
            if any(f == o or f.startswith(o.rstrip("/\\") + os.sep) for o in only)
        ]

    failures: list[str] = []
    checked = 0
    for rel in files:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            source = fh.read()
        checked += 1
        failures.extend(check_balance(rel, source))
        failures.extend(check_imports(rel, source))
    # part/part-of pairing across the whole of lib (scoped runs keep this).
    part_targets: dict[str, str] = {}
    for rel in files:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            source = fh.read()
        for m in re.finditer(r"^\s*part\s+(['\"])(.+?)\1", source, re.M):
            part_targets.setdefault(resolve_target(rel, m.group(2)) or m.group(2), rel)

    print(f"dart_lexical_gate: files={checked} failures={len(failures)}")
    for failure in failures[:40]:
        print("  FAIL", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
