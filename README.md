# SkillLens

SkillLens 是一个面向任意 Skill 的通用自动化测评框架，用来把“测什么、怎么测、怎么报”结构化。

它支持：
- 根据 Skill 文档自动发现可测面
- 按行为规范、能力、风险自动生成用例
- 执行 Skill 测试并输出中文结构化报告
- 将**执行健康**与**覆盖完整性**分开判定

> 核心原则：覆盖率不等于通过。只要存在未解释的执行层错误，报告就必须显式暴露健康受损。

## 目录结构

- `skill/SKILL.md`：SkillLens 入口说明
- `skill/templates/`：四个模板文件
- `skill/scripts/`：两个标准库脚本
- `README.md` / `ROADMAP.md`：项目说明与迭代路线

## 现在怎么用

1. 先扫描目标 skill，生成 `action.inventory.md`
2. 再基于 inventory 填写 `test.plan.md`
3. 由用户把 `APPROVED` 改成 `true`
4. 按 plan 执行并记录 `case.runs.json`
5. 用 `build_failure_skeleton.py` 生成失败骨架，再补全报告
6. 最后写 `self_check.json` 做交付自检

示例：

```powershell
python .\skill\scripts\scan_skill.py <target_skill_dir> --out <workdir>\action.inventory.md
python .\skill\scripts\build_failure_skeleton.py <workdir>\case.runs.json <workdir>\report.md
```

## 当前能力

- 基于 Skill Profile / SKILL.md 自动发现目标
- 按 behavior_contract / capability / risk 生成测试思路
- 支持 `http_json` 型 Skill 的通用测评流程
- 输出结构化中文报告与机器可消费产物
- 单独统计执行错误、传输错误、HTTP 错误、无响应错误

## 已退役的旧版本

旧的 HTTP runner 版本已经退役，不再使用这些文件：
- `skill/invoke_test_skill.ps1`
- `skill/payload.sample.json`
- `skill/skill-profile.template.json`
- `skill/test-case-matrix.template.json`
- `skill/report.template.md`

现在的官方入口就是 `skill/SKILL.md`，目录结构以本仓库当前的 `skill/` 为准。
