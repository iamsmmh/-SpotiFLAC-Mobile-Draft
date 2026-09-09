#!/usr/bin/env python3
"""gofmt-alignment checker for the backend module.

The real gate is `gofmt -l` in CI; this tool reproduces the tabwriter
alignment rules for the three constructs gofmt aligns, so formatting drift
can be caught in a sandbox without a Go toolchain:

  1. struct field blocks: name / type / tag columns padded to the block max;
  2. const/var declaration blocks: name column padded before `=`;
  3. keyed composite literals spanning consecutive lines: value column
     padded after `key:`.

Raw string literals are skipped entirely (they are data), and lines
whose value continues on the next line (multi-pair values, nested construct
openers, trailing binary operators) end an alignment run.

Usage: python3 scripts/go_align_check.py [--fix] [paths…]
Default paths: backend/ go_backend/
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIELD_RE = re.compile(
    r'^(?P<indent>\t+)(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<pad1> +)'
    # Linear-time: one non-ambiguous character class instead of overlapping
    # alternatives (avoids catastrophic backtracking on runs of '*').
    # ':' and '=' are excluded so `body := `raw string`` cannot pose as a
    # field whose "type" is `:=` and whose "tag" is the raw string.
    r'(?P<type>[^ \t\x60:=]+)'
    r'(?P<pad2> +)(?P<tag>`[^`]*`),?(?P<comment>\s*//.*)?$'
)
# Tagless struct fields and embedded-struct/interface openers
# (`Artists []struct {`) never carry a rewritable tag, but gofmt still pads
# the *name* column across them, so they must stay in the alignment run.
FIELD_PLAIN_RE = re.compile(
    r'^(?P<indent>\t+)(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<pad1> +)'
    r'(?P<type>[^ \t\x60:=]+)'
    r'(?P<tail>\s*\{|\s*,)?(?P<comment2>\s*//.*)?$'
)
CONST_RE = re.compile(
    r'^(?P<indent>\t+)(?P<name>[A-Za-z_][A-Za-z0-9_]*) +(?P<eq>=) '
)
LITERAL_RE = re.compile(
    r'^(?P<indent>\t+)(?P<key>"[^"]*"|[A-Za-z_][A-Za-z0-9_]*):(?P<space> *)'
)
DQ_STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"')


def count_raw_string_delimiters(line: str) -> int:
    """Backticks on [line] that open/close raw string literals.

    Backticks inside interpreted ("double-quoted") strings are punctuation,
    not delimiters, so those spans are masked before counting. Interpreted
    strings never span lines in Go, which makes the per-line mask sound.
    """
    return DQ_STRING_RE.sub("", line).count("`")


def literal_line_is_alignable(match: re.Match) -> bool:
    """Whether a keyed composite-literal line participates in the value
    column alignment gofmt applies.

    gofmt aligns the values of consecutive ``Key: value,`` lines only while
    every line of the run carries exactly one pair whose value stays on that
    line. A line with a second top-level pair (``A: 1, B: 2,``) or a value
    that opens a nested multi-line construct (``Payload: map[string]any{``)
    is printed without column alignment and ends the run. Trailing ``//``
    comments do NOT end the run (gofmt keeps the value column aligned across
    them), but such lines are never rewritten — gofmt may additionally align
    a trailing-comment column this checker does not model.
    """
    masked = re.sub(r'"(?:[^"\\]|\\.)*"', '""', match.string[match.end():])
    masked = masked.rstrip()
    if masked.endswith(','):
        masked = masked[:-1]
    if '//' in masked:
        # Trailing comment: still part of the alignment run; callers keep
        # the line verbatim.
        return True
    for op in ("||", "&&", "==", "!=", "<=", ">=", "+", "-", "*", "/", "%"):
        if masked.endswith(op):
            # The value continues on the next line; gofmt prints this line
            # without column alignment and ends the run.
            return False
    depth = 0
    for ch in masked:
        if ch in '{([':
            depth += 1
        elif ch in '})]':
            depth -= 1
        elif ch == ',' and depth == 0:
            return False
    # depth != 0 => the value opens a construct closed on a later line.
    return depth == 0


def literal_line_has_comment(match: re.Match) -> bool:
    masked = re.sub(r'"(?:[^"\\]|\\.)*"', '""', match.string[match.end():])
    return '//' in masked


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
            # Members can be tag-bearing fields (FIELD_RE) or tagless
            # fields / embedded-struct openers (FIELD_PLAIN_RE, matched at
            # the same indent). gofmt pads the name column across both kinds
            # but the type->tag column only across lines whose value ends on
            # the same line (openers end with "{").
            plain_by_idx = {
                idx: FIELD_PLAIN_RE.match(lines[idx])
                for idx, m in matches
                if FIELD_RE.match(lines[idx]) is None
            }
            name_w = max(
                len((plain_by_idx.get(idx) or m).group("name"))
                for idx, m in matches
            )
            # The type->tag column forms contiguous blocks of tag-bearing
            # lines: a tagless field or embedded-struct opener
            # (FIELD_PLAIN_RE member) pads the name column but terminates
            # the tag column block, which then restarts at the next
            # tag-bearing field. Trailing comments do NOT terminate a block
            # (they are never rewritten, but their type still counts).
            streak_type_w: dict[int, int] = {}
            streak: list[tuple[int, re.Match]] = []

            def flush_streak() -> None:
                if streak:
                    width = max(
                        field_type_width(sm.group("type")) for _, sm in streak
                    )
                    for sidx, _ in streak:
                        streak_type_w[sidx] = width
                    streak.clear()

            for idx, m in matches:
                if idx in plain_by_idx:
                    flush_streak()
                else:
                    streak.append((idx, m))
            flush_streak()
            for idx, m in matches:
                line = lines[idx]
                if idx in plain_by_idx or m.group("comment"):
                    # Trailing comments are kept verbatim (gofmt may align a
                    # further comment column this checker does not model);
                    # tagless fields / openers have no tag cell to rewrite.
                    # Both still count towards the widths above.
                    continue
                type_w = streak_type_w[idx]
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
                if literal_line_has_comment(m):
                    # Comment lines stay verbatim; they still count towards
                    # key_w above (gofmt keeps the value column aligned
                    # across trailing comments).
                    continue
                rebuilt = (
                    f'{m.group("indent")}{m.group("key")}:'
                    + " " * (key_w - len(m.group("key")) + 1)
                    + line[m.end():].lstrip()
                )
                if line != rebuilt:
                    lines[idx] = rebuilt
                    changed = True

    # Lines inside raw string literals (`...`) are data, not code: gofmt
    # never aligns them, so they must not match anything and always break
    # runs. Backtick parity is tracked with interpreted strings masked.
    in_raw_string = False
    raw_line = [False] * len(lines)
    for k, ln in enumerate(lines):
        raw_line[k] = in_raw_string
        if count_raw_string_delimiters(ln) % 2 == 1:
            in_raw_string = not in_raw_string

    # Walk the file, collecting contiguous runs of aligned constructs.
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        in_struct = False
        m_field = None if raw_line[i] else FIELD_RE.match(line)
        m_const = None if raw_line[i] else CONST_RE.match(line)
        m_lit = None if raw_line[i] else LITERAL_RE.match(line)
        m_plain = None if raw_line[i] else FIELD_PLAIN_RE.match(line)
        if m_field or m_const or m_lit or (m_plain and not m_field):
            mode = (
                "field"
                if m_field or m_plain
                else "const"
                if m_const
                else "literal"
            )
            group = []
            j = i
            while j < n:
                if raw_line[j]:
                    break
                if mode == "field":
                    mj = FIELD_RE.match(lines[j]) or FIELD_PLAIN_RE.match(lines[j])
                elif mode == "const":
                    mj = CONST_RE.match(lines[j])
                else:
                    mj = LITERAL_RE.match(lines[j])
                if mj is None or mj.group("indent") != (
                    m_field or m_const or m_lit or m_plain
                ).group("indent"):
                    break
                if mode == "literal" and not literal_line_is_alignable(mj):
                    break
                group.append((j, mj))
                j += 1
            if not group:
                # The run starts on a line gofmt never aligns (multi-pair or
                # multi-line value); skip it so the walk cannot stall.
                i += 1
                continue
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
    targets = args or [
        os.path.join(ROOT, "backend"),
        os.path.join(ROOT, "go_backend"),
    ]
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
