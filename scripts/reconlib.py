#!/usr/bin/env python3
"""Small helper for parsing program YAML and processing recon output."""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
from typing import Any, Dict, List


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    return value


def load_program(path: str | Path) -> Dict[str, Any]:
    data: Dict[str, Any] = {}
    current_list: str | None = None

    for raw in Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        if line.startswith(" ") or line.startswith("\t"):
            if current_list and line.lstrip().startswith("- "):
                data.setdefault(current_list, []).append(
                    parse_scalar(line.lstrip()[2:])
                )
            continue

        current_list = None
        if ":" not in line:
            continue

        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not value:
            data[key] = []
            current_list = key
        else:
            data[key] = parse_scalar(value)

    return data


def matches(candidate: str, pattern: str) -> bool:
    if "*" in pattern or "?" in pattern or "[" in pattern:
        return fnmatch.fnmatchcase(candidate, pattern)
    return candidate == pattern


def cmd_get(args: argparse.Namespace) -> int:
    program = load_program(args.yaml)
    value = program.get(args.key)
    if isinstance(value, list):
        for item in value:
            print(item)
        return 0
    if value is not None:
        print(value)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    program = load_program(args.yaml)
    values = program.get(args.key, [])
    if isinstance(values, list):
        for item in values:
            print(item)
    elif values is not None:
        print(values)
    return 0


def cmd_filter_scope(args: argparse.Namespace) -> int:
    program = load_program(args.yaml)
    in_scope: List[str] = program.get("in_scope", []) or []
    out_scope: List[str] = program.get("out_of_scope", []) or []

    seen = set()
    output: List[str] = []
    for raw in Path(args.input).read_text().splitlines():
        candidate = raw.strip()
        if not candidate or candidate in seen:
            continue
        if not any(matches(candidate, scope) for scope in in_scope):
            continue
        if any(matches(candidate, scope) for scope in out_scope):
            continue
        seen.add(candidate)
        output.append(candidate)

    Path(args.output).write_text("\n".join(output) + ("\n" if output else ""))
    return 0


def cmd_filter_out_scope(args: argparse.Namespace) -> int:
    program = load_program(args.yaml)
    out_scope: List[str] = program.get("out_of_scope", []) or []

    seen = set()
    output: List[str] = []
    for raw in Path(args.input).read_text().splitlines():
        candidate = raw.strip()
        if not candidate or candidate in seen:
            continue
        if any(matches(candidate, scope) for scope in out_scope):
            continue
        seen.add(candidate)
        output.append(candidate)

    Path(args.output).write_text("\n".join(output) + ("\n" if output else ""))
    return 0


def add_program(record: Any, program: str) -> Any:
    if isinstance(record, dict):
        updated = dict(record)
        updated["program"] = program
        return updated
    return record


def cmd_annotate_findings(args: argparse.Namespace) -> int:
    input_path = Path(args.input)
    if not input_path.exists() or input_path.stat().st_size == 0:
        Path(args.output).write_text("[]\n")
        return 0

    text = input_path.read_text().strip()
    records: List[Any]
    if not text:
        records = []
    elif text.startswith("["):
        records = json.loads(text)
    else:
        records = [json.loads(line) for line in text.splitlines() if line.strip()]

    annotated = [add_program(record, args.program) for record in records]
    Path(args.output).write_text(json.dumps(annotated, indent=2, sort_keys=True) + "\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    get_parser = sub.add_parser("get")
    get_parser.add_argument("yaml")
    get_parser.add_argument("key")
    get_parser.set_defaults(func=cmd_get)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("yaml")
    list_parser.add_argument("key")
    list_parser.set_defaults(func=cmd_list)

    filter_parser = sub.add_parser("filter-scope")
    filter_parser.add_argument("yaml")
    filter_parser.add_argument("input")
    filter_parser.add_argument("output")
    filter_parser.set_defaults(func=cmd_filter_scope)

    out_filter_parser = sub.add_parser("filter-out-scope")
    out_filter_parser.add_argument("yaml")
    out_filter_parser.add_argument("input")
    out_filter_parser.add_argument("output")
    out_filter_parser.set_defaults(func=cmd_filter_out_scope)

    annotate_parser = sub.add_parser("annotate-findings")
    annotate_parser.add_argument("program")
    annotate_parser.add_argument("input")
    annotate_parser.add_argument("output")
    annotate_parser.set_defaults(func=cmd_annotate_findings)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
