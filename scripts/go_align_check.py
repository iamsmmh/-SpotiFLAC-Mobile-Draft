#!/usr/bin/env python3
"""gofmt-alignment checker for the backend module.

The real gate is `gofmt -l` in CI; this tool reproduces the tabwriter
alignment rules for the three constructs gofmt aligns, so formatting drift
can be caught in a sandbox without a Go toolchain:

  1. struct field blocks: name / type / tag columns padded to the block max;
  2. const/var declaration blocks: name column padded before `=`;
  3. keyed composite literals spanning consecutive lines: value column
     padded after `key:`.

Usage: python3 scripts/go_align_check.py [--fix] [paths…]
Default paths: backend/
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIELD_RE = re.compile(
    r'^(?P<indent>\t+)(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<pad1> +)'
    r'(?P<type>(?:\[\]|\*|map\[[^\]]+\]|chan |func\([^)]*\)|[A-Za-z0-9_\.\[\]\*])+?)'
    r'(?P<pad2> +)(?P<tag>`[^`]*`),?$'
)
CONST_RE = re.compile(
    r'^(?P<indent>\t+)(?P<name>[A-Za-z_][A-Za-z0-9_]*) +(?P<eq>=) '
)
LITERAL_RE = re.compile(
    r'^(?P<indent>\t+)(?P<key>"[^"]*"|[A-Za-z_][A-Za-z0-9_]*):(?P<space> *)'
)


def field_type_width(type_text: str) -> int:
    # gofmt counts the type column in cells; brackets/asterisks count as-is.
    return len(type_text)


def process(content: str) -> tuple[str, bool]:
    lines = content.split("\n")
    changed = False

    def realign(matches: list[tuple[int, re.Match]], mode: str) -> None:
        nonlocal changed
        if len(matches) < 2:
            return
        if mode == "field":
            name_w = max(len(m.group("name")) for _, m in matches)
            type_w = max(field_type_width(m.group("type")) for _, m in matches)
            for idx, m in matches:
                line = lines[idx]
                rebuilt = (
                    f'{m.group("indent")}{m.group("name")}'
                    + " " * (name_w - len(m.group("name")) + 1)
                    + m.group("type")
                    + " " * (type_w - field_type_width(m.group("type")) + 1)
                    + m.group("tag")
                )
                if line != rebuilt:
                    lines[idx] = rebuilt
                    changed = True
        elif mode == "const":
            name_w = max(len(m.group("name")) for _, m in matches)
            for idx, m in matches:
                line = lines[idx]
                rebuilt = (
                    f'{m.group("indent")}{m.group("name")}'
                    + " " * (name_w - len(m.group("name")) + 1)
                    + "= "
                    + line[m.end():]
                )
                if line != rebuilt:
                    lines[idx] = rebuilt
                    changed = True
        elif mode == "literal":
            key_w = max(len(m.group("key")) for _, m in matches)
            for idx, m in matches:
                line = lines[idx]
                rebuilt = (
                    f'{m.group("indent")}{m.group("key")}:'
                    + " " * (key_w - len(m.group("key")) + 1)
                    + line[m.end():].lstrip()
                )
                if line != rebuilt:
                    lines[idx] = rebuilt
                    changed = True

    # Walk the file, collecting contiguous runs of aligned constructs.
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        in_struct = False
        m_field = FIELD_RE.match(line)
        m_const = CONST_RE.match(line)
        m_lit = LITERAL_RE.match(line)
        if m_field or m_const or m_lit:
            mode = "field" if m_field else "const" if m_const else "literal"
            group = []
            j = i
            while j < n:
                mj = (
                    FIELD_RE.match(lines[j])
                    if mode == "field"
                    else CONST_RE.match(lines[j])
                    if mode == "const"
                    else LITERAL_RE.match(lines[j])
                )
                if mj is None or mj.group("indent") != (
                    m_field or m_const or m_lit
                ).group("indent"):
                    break
                group.append((j, mj))
                j += 1
            if mode == "const":
                # Only within a parenthesized block is alignment applied.
                block = "\n".join(lines[max(0, i - 8):i])
                in_struct = block.rstrip().endswith("(")
            if mode != "const" or in_struct:
                realign(group, mode)
            i = j
            continue
        i += 1

    return "\n".join(lines), changed


def main() -> int:
    args = sys.argv[1:]
    fix = "--fix" in args
    args = [a for a in args if a != "--fix"]
    targets = args or [os.path.join(ROOT, "backend")]
    failures = []
    for target in targets:
        for base, dirs, names in os.walk(target):
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in sorted(names):
                if not name.endswith(".go"):
                    continue
                path = os.path.join(base, name)
                rel = os.path.relpath(path, ROOT)
                with open(path, encoding="utf-8") as fh:
                    original = fh.read()
                aligned, _ = process(original)
                if aligned != original:
                    if fix:
                        with open(path, "w", encoding="utf-8") as fh:
                            fh.write(aligned)
                        print(f"fixed {rel}")
                    else:
                        failures.append(rel)
    if failures:
        print("gofmt alignment drift in:")
        for failure in failures:
            print("  ", failure)
        print("run: python3 scripts/go_align_check.py --fix")
        return 1
    print("go_align_check: all aligned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
