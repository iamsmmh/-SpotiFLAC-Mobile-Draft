#!/usr/bin/env python3
"""Symbol-existence check for the discovery sources.

`dart analyze` is not runnable in this environment, so this is the next best
cheap guard: it catches the bug class that actually broke earlier drafts —
calling a helper that was remembered rather than read (`jsonEncodeSafe`,
`const _Json()`, `errorWidget:` with the wrong shape).

Method
------
1.  Collect every capitalised identifier and every called function name used in
    the *new* discovery sources.
2.  Build two whitelists from code that already ships and compiles:
      * names declared anywhere under `lib/` (class / enum / mixin / typedef /
        extension / top-level fn / const / final);
      * names *used* anywhere in the pre-existing (non-discovery) sources, which
        covers Flutter, Dart and third-party package identifiers we cannot see.
3.  Report a name that appears in neither list.

Known blind spots (documented so nobody trusts it too far):
  * it checks spelling and existence, not signatures, arity, named-vs-positional
    arguments, nullability or generic parameters;
  * a name declared in a file the new code forgot to import still passes;
  * private names are matched per-file.

`main.dart` and `ecosystem_database.dart` are deliberately *not* in the default
set: the whitelist above is built from non-discovery sources, and `main.dart` is
the only caller of `runApp`/`runZonedGuarded`/`WidgetsFlutterBinding`, so it
would report Flutter's own API as unknown. Those two files are covered by
`check_discovery_dart.py` instead.

Usage:  python3 scripts/check_discovery_symbols.py [paths...]
Exit 0 = clean, 1 = problems found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"

DISCOVERY_DIRS = [
    LIB / "engine" / "discovery",
    LIB / "ecosystem" / "discovery",
    LIB / "screens" / "discovery",
]
DISCOVERY_FILES = [
    LIB / "providers" / "discovery_providers.dart",
    LIB / "providers" / "playback_statistics_provider.dart",
    LIB / "screens" / "for_you_screen.dart",
    LIB / "ecosystem" / "ecosystem.dart",
]

DECL_RE = re.compile(
    r"""^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+|mixin\s+)*
        \s*(?:class|enum|mixin|typedef|extension)\s+
        ([A-Z_][A-Za-z0-9_]*)""",
    re.VERBOSE,
)
# `final Foo Function() bar;` and `required double Function(X) bar,` — a
# function-typed binding is callable even though no `bar(` declaration exists.
DECL_FIELD_FN_RE = re.compile(
    r"""^\s*(?:final|late|var|required)?[^=;]*\bFunction\b[^=;]*\b([a-z_][A-Za-z0-9_]*)\s*[;=,)]""",
    re.VERBOSE,
)
# `static`/`const`/… are optional because a method declaration inside a
# class has no modifier. A statement such as `return foo(` must not count as a
# declaration of `foo` — control-flow keywords are excluded up front (the type
# part below would otherwise swallow `return` as a return type).
DECL_FN_RE = re.compile(
    r"""^(?!\s*(?:return|throw|await|yield|case|assert)\b)
        \s*(?:(?:static|const|final|external|abstract)\s+)*
        [A-Za-z_][A-Za-z0-9_<>,?\[\].\s]*?\b([a-z_][A-Za-z0-9_]*)\s*[(<]""",
    re.VERBOSE,
)
# Dart record types (`({String a, double b})`) embed `(` inside the return
# type, which defeats the general DECL_FN_RE above (its type class excludes
# parens). Method declarations such as
# `List<({String userId, double similarity})> findNeighbors(` are therefore
# not recognised as declarations and their names are mis-reported as unknown
# *calls*. This supplement collects the method name after the closing `})`
# (with an optional trailing `>` for generics such as `List<({...})>`).
DECL_RECORD_FN_RE = re.compile(
    r"""^\s*(?:(?:static|const|final|external|abstract)\s+)*
        [A-Za-z_][A-Za-z0-9_<>,?\[\].\s]*?\(\{
        ([^{}()]*?)\}\s*\)
        (?:\s*>)?\s*
        ([a-z_][A-Za-z0-9_]*)\s*[(<]""",
    re.VERBOSE,
)
CAP_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")
CALL_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*\(")

#: dart: core / dart:math / dart:async / dart:convert top-level functions that
#: are legitimately callable without a declaration anywhere under lib/.
BUILTIN_CALLS = {
    # keywords
    "if", "for", "while", "switch", "catch", "return", "await", "super",
    "assert", "throw", "do", "else",
    # dart:math
    "exp", "log", "sqrt", "pow", "min", "max", "sin", "cos", "tan", "atan",
    "atan2", "ceil", "floor", "round", "truncate", "abs", "clamp", "toDouble",
    "toInt", "Random", "nextDouble", "nextInt",
    # dart:convert
    "jsonEncode", "jsonDecode", "utf8", "base64Encode", "base64Decode",
    # dart:async
    "unawaited", "Future", "Stream",
    # common collection / core
    "where", "map", "toList", "toSet", "firstWhere", "any", "every", "fold",
    "reduce", "sort", "contains", "add", "remove", "clear", "join", "split",
    "substring", "startsWith", "endsWith", "toLowerCase", "toUpperCase", "trim",
    "isEmpty", "isNotEmpty", "parse", "tryParse", "toString", "replaceAll",
    "codeUnitAt", "hashCode", "compareTo", "call", "print", "identityHashCode",
    "Duration", "DateTime", "Uri", "File", "Directory", "Iterable", "List",
    "Map", "Set", "Object", "String", "int", "double", "bool", "num", "var",
    "final", "const", "new", "this", "null", "true", "false",
    # dart:ui / flutter painting + material names not used by pre-existing code
    "Ink", "HSLColor", "fromAHSL", "toColor", "Color", "Colors", "Icons",
    "Offset", "Size", "Rect", "Radius", "Alignment", "EdgeInsets", "Border",
    "BorderRadius", "BoxDecoration", "LinearGradient", "TextSpan", "TextStyle",
    # sqflite types (the package is a dependency; it is not under lib/)
    "Transaction", "Database", "DatabaseExecutor", "Batch",
    "ConflictAlgorithm", "Sqflite",
    # package:test / package:flutter_test matchers and harness
    "test", "group", "expect", "setUp", "tearDown", "setUpAll", "tearDownAll",
    "isTrue", "isFalse", "isNull", "isNotNull", "isEmpty", "isNotEmpty",
    "isA", "isNot", "isIn", "isInstanceOf", "throwsA", "throwsException",
    "closeTo", "greaterThan", "greaterThanOrEqualTo", "lessThan",
    "lessThanOrEqualTo", "equals", "orderedEquals", "unorderedEquals",
    "anyElement", "everyElement", "contains", "containsAll", "hasLength",
    "same", "predicate", "fails", "completes", "prints", "TestWidgetsFlutterBinding",
    "pumpWidget", "pump", "pumpAndSettle", "find", "WidgetTester", "Future",
    "singleWhere", "firstWhere", "lastWhere", "indexWhere", "cast", "expand",
    "skip", "take", "reversed", "elementAt", "insert", "insertAll", "removeAt",
    "removeLast", "removeWhere", "retainWhere", "forEach", "generate", "of",
    "unmodifiable", "filled", "from", "toMap", "entries", "keys", "values",
    "putIfAbsent", "removeWhere", "update", "map", "where", "any", "every",
    "reduce", "fold", "sort", "shuffle", "sublist", "join", "toList", "toSet",
    "padLeft", "padRight", "contains", "indexOf", "lastIndexOf", "replaceFirst",
    "compareTo", "difference", "add", "subtract", "inDays", "inMilliseconds",
    "toUtc", "toIso8601String", "tryParse", "now", "parse",
}


def strip_noise(text: str) -> str:
    """Drop comments and string literals so identifiers inside them are ignored."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth:
                if text[i] == "/" and text[i + 1 : i + 2] == "*":
                    depth += 1
                    i += 2
                    continue
                if text[i] == "*" and text[i + 1 : i + 2] == "/":
                    depth -= 1
                    i += 2
                    continue
                i += 1
            continue
        if ch == "'":
            raw = False
            quote = "'"
            i += 1
            while i < n:
                if not raw and text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append(" ")
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def is_discovery(path: Path) -> bool:
    return any(path.parent == d for d in DISCOVERY_DIRS) or path in DISCOVERY_FILES


def main(argv: list[str]) -> int:
    if argv[1:]:
        targets = [Path(a) for a in argv[1:]]
    else:
        targets = [p for d in DISCOVERY_DIRS for p in sorted(d.glob("*.dart"))]
        targets += DISCOVERY_FILES

    declared: set[str] = set()
    used_elsewhere: set[str] = set()

    for path in sorted(LIB.rglob("*.dart")):
        text = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        for line in text.splitlines():
            m = DECL_RE.match(line)
            if m:
                declared.add(m.group(1))
            fn = DECL_FN_RE.match(line)
            if fn:
                declared.add(fn.group(1))
            record_fn = DECL_RECORD_FN_RE.match(line)
            if record_fn:
                declared.add(record_fn.group(2))
            field_fn = DECL_FIELD_FN_RE.match(line)
            if field_fn:
                declared.add(field_fn.group(1))
            for name in re.findall(
                r"^[ \t]*(?:static\s+)?(?:const|final|late|var)\s+"
                r"(?:[A-Za-z_][A-Za-z0-9_<>,?\[\]\s]*?\s)?([a-z_][A-Za-z0-9_]*)\s*=",
                line,
            ):
                declared.add(name)
        if not is_discovery(path):
            used_elsewhere |= set(CAP_RE.findall(text))
            used_elsewhere |= set(CALL_RE.findall(text))

    problems: list[str] = []
    for path in targets:
        if not path.exists():
            problems.append(f"{path}: file not found")
            continue
        text = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        local_declared = set(declared)
        for line in text.splitlines():
            m = DECL_RE.match(line)
            if m:
                local_declared.add(m.group(1))
            fn = DECL_FN_RE.match(line)
            if fn:
                local_declared.add(fn.group(1))
            record_fn = DECL_RECORD_FN_RE.match(line)
            if record_fn:
                local_declared.add(record_fn.group(2))
        for name in sorted(set(CAP_RE.findall(text))):
            if name.startswith("_") or name.isupper():
                continue
            if name in local_declared or name in used_elsewhere:
                continue
            if name in BUILTIN_CALLS:
                continue
            problems.append(f"{path}: unknown type name '{name}'")
        for name in sorted(set(CALL_RE.findall(text))):
            if name in local_declared or name in used_elsewhere:
                continue
            if name in BUILTIN_CALLS:
                continue
            problems.append(f"{path}: unknown function call '{name}()'")

    for problem in problems:
        print(problem)
    print(f"symbol check: {len(targets)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
