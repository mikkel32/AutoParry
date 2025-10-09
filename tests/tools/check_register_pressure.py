#!/usr/bin/env python3
"""Check AutoParry sources for Luau register pressure regressions."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TARGETS = [ROOT / "loader.lua", ROOT / "src"]

Token = Tuple[str, str, int]
KEYWORDS = {
    "and",
    "break",
    "do",
    "else",
    "elseif",
    "end",
    "false",
    "for",
    "function",
    "if",
    "in",
    "local",
    "nil",
    "not",
    "or",
    "repeat",
    "return",
    "then",
    "true",
    "until",
    "while",
    "continue",
}

VALUE_TOKEN_KINDS = {
    "name",
    "number",
    "string",
    "function",
    "true",
    "false",
    "nil",
    "{",
    "(",
    "[",
    "ellipsis",
}


@dataclass
class FunctionReport:
    path: Path
    name: str
    start_line: int
    local_count: int
    max_table_fields: int
    table_hotspot_line: Optional[int]
    max_line_tokens: int
    busiest_line: Optional[int]
    max_closure_depth: int

    @property
    def display_name(self) -> str:
        return self.name or "<anonymous>"


@dataclass
class FileReport:
    path: Path
    functions: List[FunctionReport]

    @property
    def total_locals(self) -> int:
        return sum(function.local_count for function in self.functions)

    @property
    def function_count(self) -> int:
        return len(self.functions)

    @property
    def max_local_count(self) -> int:
        if not self.functions:
            return 0
        return max(function.local_count for function in self.functions)

    @property
    def busiest_function(self) -> Optional[FunctionReport]:
        if not self.functions:
            return None
        return max(self.functions, key=lambda function: function.local_count)

    @property
    def max_closure_depth(self) -> int:
        if not self.functions:
            return 0
        return max(function.max_closure_depth for function in self.functions)

    @property
    def max_table_fields(self) -> int:
        if not self.functions:
            return 0
        return max(function.max_table_fields for function in self.functions)

    @property
    def max_line_tokens(self) -> int:
        if not self.functions:
            return 0
        return max(function.max_line_tokens for function in self.functions)


@dataclass
class TableContext:
    field_count: int
    has_value: bool
    start_line: int


@dataclass
class FunctionScope:
    path: Path
    name: str
    start_line: int
    local_count: int
    table_stack: List[TableContext] = field(default_factory=list)
    max_table_fields: int = 0
    table_hotspot_line: Optional[int] = None
    line_token_counts: Dict[int, int] = field(default_factory=dict)
    max_closure_depth: int = 0

    def record_token(self, kind: str, line: int) -> None:
        self.line_token_counts[line] = self.line_token_counts.get(line, 0) + 1

        if kind == "{":
            if self.table_stack:
                self.table_stack[-1].has_value = True
            self.table_stack.append(TableContext(field_count=0, has_value=False, start_line=line))
            return

        if not self.table_stack:
            return

        ctx = self.table_stack[-1]
        if kind in VALUE_TOKEN_KINDS:
            ctx.has_value = True
            return

        if kind in {",", ";"}:
            if ctx.has_value:
                ctx.field_count += 1
                ctx.has_value = False
            return

        if kind == "}":
            if ctx.has_value:
                ctx.field_count += 1
                ctx.has_value = False
            if ctx.field_count > self.max_table_fields:
                self.max_table_fields = ctx.field_count
                self.table_hotspot_line = ctx.start_line
            self.table_stack.pop()
            if self.table_stack:
                self.table_stack[-1].has_value = True

    def finalise(self) -> FunctionReport:
        while self.table_stack:
            ctx = self.table_stack.pop()
            if ctx.has_value:
                ctx.field_count += 1
            if ctx.field_count > self.max_table_fields:
                self.max_table_fields = ctx.field_count
                self.table_hotspot_line = ctx.start_line

        max_line_tokens = 0
        busiest_line = None
        for line, count in self.line_token_counts.items():
            if count > max_line_tokens:
                max_line_tokens = count
                busiest_line = line

        return FunctionReport(
            path=self.path,
            name=self.name,
            start_line=self.start_line,
            local_count=self.local_count,
            max_table_fields=self.max_table_fields,
            table_hotspot_line=self.table_hotspot_line,
            max_line_tokens=max_line_tokens,
            busiest_line=busiest_line,
            max_closure_depth=self.max_closure_depth,
        )


def match_long_bracket(source: str, index: int) -> int:
    if source[index] != "[":
        return -1
    depth = 0
    cursor = index + 1
    while cursor < len(source) and source[cursor] == "=":
        depth += 1
        cursor += 1
    if cursor < len(source) and source[cursor] == "[":
        return depth
    return -1


def skip_long_bracket(source: str, index: int, eq_count: int, line: int) -> Tuple[int, int]:
    closing = "]" + ("=" * eq_count) + "]"
    cursor = index + 1 + eq_count + 1
    while cursor < len(source):
        char = source[cursor]
        if char == "\n":
            line += 1
            cursor += 1
            continue
        if source.startswith(closing, cursor):
            cursor += len(closing)
            return cursor, line
        cursor += 1
    return len(source), line


def skip_string(source: str, index: int, quote: str, line: int) -> Tuple[int, int]:
    cursor = index + 1
    while cursor < len(source):
        char = source[cursor]
        if char == "\\":
            cursor += 2
            continue
        if char == quote:
            return cursor + 1, line
        if char == "\n":
            line += 1
        cursor += 1
    return len(source), line


def tokenize(source: str) -> Iterator[Token]:
    index = 0
    line = 1
    length = len(source)

    while index < length:
        char = source[index]

        if char == "\n":
            line += 1
            index += 1
            continue

        if char in "\r\t\v\f ":
            index += 1
            continue

        if char == "-" and index + 1 < length and source[index + 1] == "-":
            index += 2
            if index < length and source[index] == "[":
                depth = match_long_bracket(source, index)
                if depth >= 0:
                    index, line = skip_long_bracket(source, index, depth, line)
                    continue
            while index < length and source[index] != "\n":
                index += 1
            continue

        if char in {'"', "'"}:
            start_line = line
            index, line = skip_string(source, index, char, line)
            yield "string", "", start_line
            continue

        if char == "[":
            depth = match_long_bracket(source, index)
            if depth >= 0:
                start_line = line
                index, line = skip_long_bracket(source, index, depth, line)
                yield "string", "", start_line
                continue
            yield "[", "[", line
            index += 1
            continue

        if char.isdigit():
            cursor = index + 1
            while cursor < length and (source[cursor].isalnum() or source[cursor] in {".", "_", "x", "X"}):
                cursor += 1
            yield "number", source[index:cursor], line
            index = cursor
            continue

        if char.isalpha() or char == "_":
            cursor = index + 1
            while cursor < length and (source[cursor].isalnum() or source[cursor] == "_"):
                cursor += 1
            value = source[index:cursor]
            kind = value if value in KEYWORDS else "name"
            yield kind, value, line
            index = cursor
            continue

        if char == ".":
            if source.startswith("...", index):
                yield "ellipsis", "...", line
                index += 3
                continue
            if source.startswith("..", index):
                yield "concat", "..", line
                index += 2
                continue
            yield ".", ".", line
            index += 1
            continue

        single = {
            "(": "(",
            ")": ")",
            "{": "{",
            "}": "}",
            ",": ",",
            ";": ";",
            ":": ":",
            "=": "=",
            "<": "<",
            ">": ">",
            "[": "[",
            "]": "]",
            "+": "+",
            "-": "-",
            "*": "*",
            "/": "/",
            "%": "%",
            "^": "^",
            "#": "#",
            "?": "?",
            "~": "~",
        }
        if char in single:
            yield single[char], single[char], line
            index += 1
            continue

        # Unknown character, skip it conservatively.
        index += 1


def gather_name(tokens: Sequence[Token], start: int) -> Tuple[List[Token], int]:
    collected: List[Token] = []
    cursor = start
    while cursor < len(tokens):
        kind, _, _ = tokens[cursor]
        if kind == "(":
            break
        collected.append(tokens[cursor])
        cursor += 1
    return collected, cursor


def format_name(tokens: Sequence[Token]) -> str:
    if not tokens:
        return "<anonymous>"
    parts: List[str] = []
    for kind, value, _ in tokens:
        if kind == "name":
            parts.append(value)
        elif kind in {".", ":", "[", "]", "number"}:
            parts.append(value)
        elif kind == "string":
            parts.append(value)
        elif kind in {"<", ">", ","}:
            parts.append(value)
    result = "".join(parts).strip()
    return result or "<anonymous>"


def parse_parameters(tokens: Sequence[Token], start: int) -> Tuple[int, int]:
    if start >= len(tokens) or tokens[start][0] != "(":
        return 0, start
    depth = 0
    count = 0
    cursor = start
    prev_kind: Optional[str] = None

    while cursor < len(tokens):
        kind, _, _ = tokens[cursor]
        if kind == "(":
            depth += 1
            if depth == 1:
                prev_kind = "("
        elif kind == ")":
            depth -= 1
            if depth == 0:
                return count, cursor
        else:
            if depth == 1:
                if kind == "name" and prev_kind in {"(", ",", "<"}:
                    count += 1
                    prev_kind = "name"
                    cursor += 1
                    continue
                if kind == "ellipsis":
                    prev_kind = "ellipsis"
                    cursor += 1
                    continue
                if kind in {",", ";"}:
                    prev_kind = ","
                    cursor += 1
                    continue
                if kind == ":":
                    prev_kind = ":"
                    cursor += 1
                    continue
                if kind == "<":
                    prev_kind = "<"
                    cursor += 1
                    continue
        cursor += 1

    return count, cursor


def count_local_names(tokens: Sequence[Token], start: int) -> int:
    count = 0
    expecting_name = True
    cursor = start
    while cursor < len(tokens):
        kind, _, _ = tokens[cursor]
        if kind == "=":
            break
        if kind == ",":
            expecting_name = True
            cursor += 1
            continue
        if kind == "name" and expecting_name:
            count += 1
            expecting_name = False
        elif kind in {"function", "end", "if", "for", "while", "repeat", "return", "local", "do"}:
            break
        cursor += 1
    return count


def count_for_variables(tokens: Sequence[Token], start: int) -> int:
    count = 0
    expecting_name = True
    cursor = start
    while cursor < len(tokens):
        kind, _, _ = tokens[cursor]
        if kind == "=" or kind == "in":
            break
        if kind == ",":
            expecting_name = True
            cursor += 1
            continue
        if kind == "name" and expecting_name:
            count += 1
            expecting_name = False
        cursor += 1
    return count


def analyse_file(path: Path) -> List[FunctionReport]:
    source = path.read_text(encoding="utf-8")
    tokens = list(tokenize(source))
    reports: List[FunctionReport] = []
    scope_stack: List[FunctionScope] = []
    block_stack: List[str] = []

    index = 0
    while index < len(tokens):
        kind, _, line = tokens[index]

        if scope_stack:
            scope_stack[-1].record_token(kind, line)

        if kind == "function":
            block_stack.append("function")
            name_tokens, param_start = gather_name(tokens, index + 1)
            name = format_name(name_tokens)
            param_count, param_end = parse_parameters(tokens, param_start)
            scope = FunctionScope(
                path=path,
                name=name,
                start_line=line,
                local_count=param_count,
            )
            scope_stack.append(scope)
            if len(scope_stack) > 1:
                for idx, ancestor in enumerate(scope_stack[:-1]):
                    depth = len(scope_stack) - 1 - idx
                    ancestor.max_closure_depth = max(ancestor.max_closure_depth, depth)
            index = param_end + 1
            continue

        if kind == "local":
            if scope_stack:
                next_kind = tokens[index + 1][0] if index + 1 < len(tokens) else None
                if next_kind == "function":
                    scope_stack[-1].local_count += 1
                else:
                    scope_stack[-1].local_count += count_local_names(tokens, index + 1)

        elif kind == "for":
            block_stack.append("for")
            if scope_stack:
                scope_stack[-1].local_count += count_for_variables(tokens, index + 1)

        elif kind in {"if", "while"}:
            block_stack.append(kind)

        elif kind == "do":
            block_stack.append("do")

        elif kind == "repeat":
            block_stack.append("repeat")

        elif kind == "until":
            if block_stack and block_stack[-1] == "repeat":
                block_stack.pop()

        elif kind == "end":
            if block_stack:
                marker = block_stack.pop()
                if marker == "function" and scope_stack:
                    scope = scope_stack.pop()
                    reports.append(scope.finalise())

        index += 1

    while scope_stack:
        reports.append(scope_stack.pop().finalise())

    return reports


def iter_lua_files(paths: Iterable[Path]) -> Iterator[Path]:
    seen: Dict[Path, None] = {}
    for path in paths:
        resolved = path
        if resolved.is_dir():
            for candidate in sorted(resolved.rglob("*.lua")):
                if candidate.is_file():
                    seen.setdefault(candidate.resolve(), None)
        elif resolved.suffix == ".lua" and resolved.exists():
            seen.setdefault(resolved.resolve(), None)
    yield from sorted(seen.keys())


def run(limit: int, targets: Sequence[Path]) -> int:
    files = list(iter_lua_files(targets))
    reports: List[FunctionReport] = []
    file_reports: List[FileReport] = []

    for path in files:
        per_file_reports = analyse_file(path)
        if not per_file_reports:
            continue
        reports.extend(per_file_reports)
        file_reports.append(FileReport(path=path, functions=per_file_reports))

    if not reports:
        print("[register-pressure] No functions discovered in provided targets.")
        return 0

    reports_by_pressure = sorted(
        reports, key=lambda item: item.local_count, reverse=True
    )

    violations: List[Tuple[FunctionReport, List[str]]] = []
    for report in reports_by_pressure:
        if report.local_count > limit:
            reasons: List[str] = [
                f"function is too large: declares {report.local_count} locals (limit {limit})",
            ]
            if report.max_line_tokens > 120 and report.busiest_line is not None:
                reasons.append(
                    "inlines too much logic: "
                    f"line {report.busiest_line} contains a large expression ({report.max_line_tokens} tokens)"
                )
            if report.max_table_fields > limit and report.table_hotspot_line is not None:
                reasons.append(
                    "constructs a heavy table literal: "
                    f"near line {report.table_hotspot_line} expands to {report.max_table_fields} fields"
                )
            if report.max_closure_depth > 3:
                reasons.append(
                    "contains deeply nested closures: "
                    f"depth reaches {report.max_closure_depth} levels"
                )
            violations.append((report, reasons))

    file_hotspots: List[Tuple[FileReport, List[str]]] = []
    for report in file_reports:
        if report.total_locals > limit:
            reasons = [
                f"aggregates {report.total_locals} locals across the file (limit {limit})",
            ]
            busiest = report.busiest_function
            if busiest is not None:
                rel = busiest.path.relative_to(ROOT)
                reasons.append(
                    "dominant function driver: "
                    f"{busiest.display_name} ({rel}:{busiest.start_line}) consumes {busiest.local_count} locals"
                )
            if report.max_line_tokens > 120:
                reasons.append(
                    "widespread inline logic detected: file hosts an expression with "
                    f"{report.max_line_tokens} tokens"
                )
            if report.max_table_fields > limit:
                reasons.append(
                    "contains table literals that expand beyond the register budget"
                )
            if report.max_closure_depth > 3:
                reasons.append(
                    "nested closure families increase captured register pressure"
                )
            file_hotspots.append((report, reasons))

    top = reports_by_pressure[0]
    print(
        f"[register-pressure] Analysed {len(reports_by_pressure)} functions across {len(files)} file(s)."
    )
    print(
        f"[register-pressure] Peak local count: {top.local_count} in {top.display_name} ({top.path.relative_to(ROOT)}:{top.start_line})."
    )
    if top.max_line_tokens:
        line_info = (
            f"line {top.busiest_line}"
            if top.busiest_line is not None
            else "an unknown line"
        )
        print(
            f"[register-pressure] Busiest expression: {top.max_line_tokens} tokens on {line_info}."
        )
    if top.max_table_fields:
        hotspot = (
            f"line {top.table_hotspot_line}" if top.table_hotspot_line is not None else "an unknown line"
        )
        print(
            f"[register-pressure] Largest table literal observed: {top.max_table_fields} entries near {hotspot}."
        )

    total_locals = sum(report.local_count for report in reports_by_pressure)
    print(
        f"[register-pressure] Local register summary: {total_locals} total across {len(reports_by_pressure)} function(s).",
    )
    for report in reports_by_pressure:
        rel = report.path.relative_to(ROOT)
        register_word = "register" if report.local_count == 1 else "registers"
        print(
            f"  - {rel}:{report.start_line} → {report.display_name}: {report.local_count} local {register_word}"
        )

    if file_reports:
        print("[register-pressure] File register summary (descending by total locals):")
        for file_report in sorted(
            file_reports, key=lambda item: item.total_locals, reverse=True
        ):
            rel_path = file_report.path.relative_to(ROOT)
            fn_word = "function" if file_report.function_count == 1 else "functions"
            print(
                "  - "
                f"{rel_path}: {file_report.total_locals} locals across {file_report.function_count} {fn_word}; "
                f"peak {file_report.max_local_count} in "
                f"{file_report.busiest_function.display_name if file_report.busiest_function else '<none>'}"
            )

    exit_code = 0

    if violations:
        print(
            f"[register-pressure] Detected {len(violations)} function(s) exceeding the {limit}-register budget:"
        )
        for report, reasons in violations:
            rel = report.path.relative_to(ROOT)
            print(f"  - {rel}:{report.start_line} → {report.display_name}")
            for reason in reasons:
                print(f"      · {reason}")
        print(
            "[register-pressure] Consider splitting large functions, hoisting inline expressions, "
            "or reducing nested closures/table literals."
        )
        exit_code = 1

    if file_hotspots:
        print(
            f"[register-pressure] Advisory: {len(file_hotspots)} file(s) exceed the suggested {limit}-register aggregate budget:"
        )
        for report, reasons in file_hotspots:
            rel = report.path.relative_to(ROOT)
            print(f"  - {rel}")
            for reason in reasons:
                print(f"      · {reason}")
        print(
            "[register-pressure] Consider splitting modules, extracting helper utilities, or delaying heavy table construction to balance file-level pressure."
        )

    if exit_code:
        return exit_code

    if top.local_count > int(limit * 0.75):
        print(
            "[register-pressure] Warning: functions are approaching the register ceiling. Consider refactoring to maintain headroom."
        )

    if file_reports:
        max_file_total = max(report.total_locals for report in file_reports)
        if max_file_total > int(limit * 0.75):
            busiest_file = max(
                file_reports, key=lambda report: report.total_locals
            )
            print(
                "[register-pressure] Warning: modules are accumulating high aggregate pressure. "
                f"{busiest_file.path.relative_to(ROOT)} carries {busiest_file.total_locals} locals in total."
            )

    print("[register-pressure] All functions are within the configured register budget.")
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Detect Luau register pressure regressions caused by overly large functions."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=200,
        help="Maximum allowed local register count per function (default: 200).",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=DEFAULT_TARGETS,
        help="Files or directories to inspect (default: loader.lua and src/).",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    resolved_targets = [
        path if path.is_absolute() else ROOT / path for path in args.paths
    ]
    return run(args.limit, resolved_targets)


if __name__ == "__main__":
    raise SystemExit(main())
