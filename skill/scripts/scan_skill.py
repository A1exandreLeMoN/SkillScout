#!/usr/bin/env python3
"""SkillLens: 机械扫描目标 skill 目录，生成 action.inventory 草稿。"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HEADING_RE = re.compile(r"^(#{2,3})\s+(.+?)\s*$")
INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"警告：{path} 不存在", file=sys.stderr)
    except OSError as exc:
        print(f"警告：读取 {path} 失败：{exc}", file=sys.stderr)
    return ""


def extract_headings(md_text: str) -> list[tuple[str, int]]:
    headings: list[tuple[str, int]] = []
    for line in md_text.splitlines():
        match = HEADING_RE.match(line)
        if match:
            headings.append((match.group(2).strip(), len(match.group(1))))
    return headings


def extract_inline_code(md_text: str) -> list[str]:
    stripped = CODE_FENCE_RE.sub("", md_text)
    seen: list[str] = []
    for item in INLINE_CODE_RE.findall(stripped):
        if item not in seen:
            seen.append(item)
        if len(seen) >= 50:
            break
    return seen


def list_files(directory: Path, suffixes: set[str]) -> list[str]:
    if not directory.exists():
        print(f"警告：目录不存在：{directory}", file=sys.stderr)
        return []
    files = [p.name for p in directory.iterdir() if p.is_file() and p.suffix.lower() in suffixes]
    return sorted(files, key=str.lower)


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan a skill directory and emit an inventory draft.")
    parser.add_argument("target", help="目标 skill 目录")
    parser.add_argument("--out", default=None, help="输出到指定 Markdown 文件；不提供则打印到 stdout")
    args = parser.parse_args()

    target = Path(args.target)
    if not target.is_dir():
        print(f"错误：{target} 不是目录", file=sys.stderr)
        return 2

    skill_md = target / "SKILL.md"
    md_text = read_text(skill_md) if skill_md.exists() else ""
    if not skill_md.exists():
        print(f"警告：目标 skill 缺少 SKILL.md：{skill_md}", file=sys.stderr)

    headings = extract_headings(md_text) if md_text else []
    inline_code = extract_inline_code(md_text) if md_text else []
    scripts = list_files(target / "scripts", {".py", ".ps1", ".sh"})
    templates = list_files(target / "templates", {".md", ".json", ".yml", ".yaml"})

    lines: list[str] = []
    lines.append(f"# [草稿] Action Inventory: {target.name}")
    lines.append("")
    lines.append("> 本文件由 scan_skill.py 机械生成，仅供 agent 参考。")
    lines.append("> agent 必须基于本草稿做语义判断（合并、删减、补充），产出最终 action.inventory.md。")
    if not md_text:
        lines.append("> **注意：目标 skill 没有 SKILL.md**")
    lines.append("")

    lines.append("## 候选 action（来自 SKILL.md 标题）")
    lines.append("| 标题 | 层级 |")
    lines.append("|------|------|")
    if headings:
        for title, level in headings:
            lines.append(f"| {title} | {'#' * level} |")
    else:
        lines.append("| — | — |")
    lines.append("")

    lines.append("## 候选 action（来自脚本文件）")
    lines.append("| 文件名 |")
    lines.append("|--------|")
    if scripts:
        for name in scripts:
            lines.append(f"| {name} |")
    else:
        lines.append("| — |")
    lines.append("")

    lines.append("## 候选 action（来自 SKILL.md 反引号引用）")
    lines.append("| 引用 |")
    lines.append("|------|")
    if inline_code:
        for item in inline_code:
            lines.append(f"| `{item}` |")
    else:
        lines.append("| — |")
    lines.append("")

    lines.append("## 发现的模板文件")
    lines.append("| 文件名 |")
    lines.append("|--------|")
    if templates:
        for name in templates:
            lines.append(f"| {name} |")
    else:
        lines.append("| — |")
    lines.append("")

    output = "\n".join(lines)
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
        if not output.endswith("\n"):
            sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
