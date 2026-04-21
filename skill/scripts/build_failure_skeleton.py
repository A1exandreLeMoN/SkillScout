#!/usr/bin/env python3
"""SkillLens: 根据 case.runs.json 生成 report.md 里的失败骨架。"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

BEGIN = "<!-- FAILURE_SKELETON_BEGIN -->"
END = "<!-- FAILURE_SKELETON_END -->"
HEADER = (
    "| Case ID | 输入要点 | 实际返回（截取） | 失败类型 | 为什么算失败 | 重现方式 | 严重级别 |\n"
    "|---------|----------|------------------|----------|--------------|----------|----------|"
)


def reflow_spaces(text: str) -> str:
    return " ".join(text.split())


def truncate(text: Any, limit: int) -> str:
    value = "" if text is None else str(text)
    value = value.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    value = value.replace("|", r"\|")
    value = reflow_spaces(value)
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 1)] + "…"


def load_cases(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        for key in ("cases", "case_runs", "runs"):
            value = data.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    raise ValueError("case.runs.json 顶层必须是列表，或包含 cases/case_runs/runs 列表")


def last_output(case: dict[str, Any]) -> str:
    runs = case.get("runs")
    if not isinstance(runs, list) or not runs:
        return ""
    last = runs[-1]
    if isinstance(last, dict):
        return str(last.get("output", ""))
    return str(last)


def build_row(case: dict[str, Any]) -> str:
    failure_type = case.get("failure_type") or "unknown"
    severity = case.get("severity") or "<需 agent 填>"
    return (
        f"| {truncate(case.get('case_id', ''), 40)} | "
        f"{truncate(case.get('input_summary', ''), 80)} | "
        f"{truncate(last_output(case), 120)} | "
        f"{truncate(failure_type, 24)} | <需 agent 填> | <需 agent 填> | {truncate(severity, 16)} |"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Build failure skeleton rows into a report markdown file.")
    parser.add_argument("runs_json", help="case.runs.json")
    parser.add_argument("report_md", help="report.md")
    args = parser.parse_args()

    runs_path = Path(args.runs_json)
    report_path = Path(args.report_md)

    try:
        cases = load_cases(runs_path)
    except Exception as exc:  # noqa: BLE001 - 需要把结构错误直接暴露给调用方
        print(f"错误：读取 {runs_path} 失败：{exc}", file=sys.stderr)
        return 2

    failures = [case for case in cases if str(case.get("final_status", "")).lower() in {"fail", "error"}]

    try:
        report_text = report_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"错误：读取 {report_path} 失败：{exc}", file=sys.stderr)
        return 2

    if BEGIN not in report_text or END not in report_text:
        print(f"错误：{report_path} 缺少 FAILURE_SKELETON 标记", file=sys.stderr)
        return 2

    body_lines = [HEADER]
    body_lines.extend(build_row(case) for case in failures)
    injection = "\n".join(body_lines)

    pre, _, rest = report_text.partition(BEGIN)
    _, _, post = rest.partition(END)
    new_text = pre + BEGIN + "\n" + injection + "\n" + END + post
    report_path.write_text(new_text, encoding="utf-8")

    inserted = len(failures)
    print(f"Inserted {inserted} failure rows (runs fail/error count: {inserted})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
