---
name: SkillLens
description: 面向任意 Claude Skill 的通用测评方法论。接到“测一个 skill / 出测试报告 / 评估某个技能”时，按九条原则和五阶段流程，自动推导测试方案、执行、报告和自检。
---

# SkillLens

SkillLens 是一个通用测评方法论。它不预置具体业务，只负责把“应该测什么、怎么测、怎么汇报”结构化。

它适合用于：
- 评估任意 Claude Skill 是否可用
- 为某个 skill 生成结构化测试方案
- 执行测试并输出中文报告
- 识别覆盖缺口、失败类型和执行健康

它不负责：
- 代替实际执行器去跑 HTTP / 工具 / 对话
- 替代通用测试框架
- 自动打分并替代人类最终判断

## 何时使用

当用户说出以下意图之一时，使用本 skill：
- “测一下这个 skill”
- “评估这个功能 / 能力”
- “给我出个测试报告”
- “SkillLens”
- 用户给出一个 skill 目录或 `SKILL.md`，并希望知道它是否可测、怎么测

## 目录结构

本 skill 只允许存在以下 7 个文件：

```text
skill/
├── SKILL.md
├── templates/
│   ├── action.inventory.template.md
│   ├── test.plan.template.md
│   ├── report.template.md
│   └── summary.template.md
└── scripts/
    ├── scan_skill.py
    └── build_failure_skeleton.py
```

不要在这个目录里额外新增 README、CHANGELOG、ROADMAP、__init__.py、pyproject.toml、requirements.txt 等文件。

## 九条思考原则

### 原则 0：先清点可测面，再决定测什么
任何测试动作开始前，必须先把目标 skill 的可测面清点清楚。

可测面包括但不限于：
- action
- 模式
- 输入分支
- 角色 / 触发方式
- 边界与异常
- 副作用

可观察动作：
- 先生成 `action.inventory.md`
- inventory 为空时，不得进入下一阶段

### 原则 1：从失败假设出发，不从成功演示出发
测试的目标是暴露问题，不是展示功能。

默认假设：
- 边界会出错
- 组合会出错
- 异常输入会出错

可观察动作：
- `test.plan.md` 里的案例必须包含失败路径、边界路径、异常路径

### 原则 2：把输出放回用户的下一步动作里
输出只有能被阅读、转发、粘贴、继续处理，才算有效输出。

可观察动作：
- 将格式错乱、截断、不可复制的输出，视为失败或缺陷
- 对“结果透明度”单独设计 case

### 原则 3：沉默也是信息
空响应、无结果、无状态码，不等于成功。

可观察动作：
- 对模糊输入、越权操作、未支持功能、沉默行为都要建 case
- 至少保留一个“预期拒绝 / 报错 / 空响应”的探测 case

### 原则 4：边界揭示设计底色
空输入、超长输入、特殊字符、嵌套结构、非法编码、越权请求、未认证请求，都用来检验设计是否扎实。

可观察动作：
- inventory 中每个 action 至少覆盖 1 个边界输入

### 原则 5：副作用必须闭环
写操作、发请求、修改外部状态，都必须确认、可回滚、可追踪。

可观察动作：
- 涉及写入 / 删除 / 发布 / 提交的 case，必须显式标记“未确认 -> 应拒绝”和“已确认 -> 应执行且可追踪”

### 原则 6：一次成功不是证据，稳定成功才是
任何涉及 LLM、随机、采样、外部依赖的行为，都必须重复验证。

可观察动作：
- 关键 case 要重复执行
- 在 plan 里标明重复次数与稳定性判定规则

### 原则 7：分清 skill 错、环境错、评估错
失败时必须判断归因，而不是笼统写“失败”。

可观察动作：
- `case.runs.json` 里的失败必须标注 `skill_error` / `env_error` / `eval_error` / `unknown`
- `unknown` 必须附带后续处理计划

### 原则 8：失败必须完整可见，不得合并或淡化
任何 silent dropping / merging / downgrading 失败的做法，均视为评估错误。

可观察动作：
- `report.md` 中失败行数必须与 `case.runs.json` 的 fail/error 数一致
- `build_failure_skeleton.py` 只能生成骨架，不能删除、合并或隐藏失败

## 五阶段工作流

### 阶段 1：理解目标

输入：
- 目标 skill 路径，或用户描述
- 若存在，读取目标 skill 的 `SKILL.md`、脚本、模板

动作：
- 可选运行 `scripts/scan_skill.py <target_skill_dir>`
- 明确本次测试粒度
- 枚举可测面
- 标注不在本次范围的部分及原因

产物：
- `action.inventory.md`

门禁：
- 没有 inventory，不进入下一阶段

### 阶段 2：设计测试

输入：
- `action.inventory.md`
- 九条原则

动作：
- 每个要测 action 至少设计 1 条成功用例 + 1 条边界/失败用例
- 涉及写操作的 action 额外满足原则 5
- 依赖 LLM / 随机性的 case 要标明重复次数
- 估算风险、假设与总数

产物：
- `test.plan.md`

门禁：
- 需要用户批准后才能进入执行阶段
- `test.plan.md` 中的审批区必须填成 `APPROVED: true` 才能执行

### 阶段 3：执行测试

输入：
- 已批准的 `test.plan.md`

动作：
- 按 plan 逐条执行
- 每条 case 的结果写入 `case.runs.json`
- 只追加，不覆盖历史
- 若遇到 plan 未覆盖的情况，暂停并告知用户，不得自行扩展 plan
- 需要重复执行的 case，按 plan 指定次数执行并记录每次结果

产物：
- `case.runs.json`

### 阶段 4：分析与报告

输入：
- `action.inventory.md`
- `test.plan.md`
- `case.runs.json`

动作：
- 运行 `scripts/build_failure_skeleton.py <case.runs.json> <report.md>`
- 基于 `templates/report.template.md` 填充其余 section
- 填充 `summary.md`
- 填写 action 覆盖表与原则覆盖表

产物：
- `report.md`
- `summary.md`

硬约束：
- `summary.md` 必须恰好 5 行内容（不计标题行）
- `report.md` 里的失败行数必须等于失败 case 数

### 阶段 5：自检

输入：
- 前述所有产物

动作：
- 检查 inventory 是否存在且非空
- 检查 plan 是否被批准
- 检查 report 里的失败行数是否与 case.runs.json 中的失败数一致
- 检查失败类型是否填写
- 检查 action 覆盖是否完整
- 检查 summary 是否 5 行

产物：
- `self_check.json`

如果任一项失败：
- 最终结论不能写成 Pass
- 必须降级

## 产物约定

### `action.inventory.md`
用途：列出所有可测 action 和排除项。

### `test.plan.md`
用途：把 inventory 变成可执行用例，并等待批准。

### `case.runs.json`
用途：按 case 逐条记录原始执行结果。

### `report.md`
用途：结构化报告。失败场景必须完整可见。

### `summary.md`
用途：5 行摘要，给人快速判断。

### `self_check.json`
用途：把自检项显式写出来，任何失败都不得隐藏。

## 脚本约定

### `scripts/scan_skill.py`
作用：
- 扫描目标 skill 目录
- 提取 `SKILL.md` 的二级 / 三级标题
- 提取脚本文件
- 提取模板文件
- 提取 `SKILL.md` 中的反引号引用
- 输出 `action.inventory.md` 草稿

要求：
- 只读
- 仅使用 Python 3.10+ 标准库
- 读取失败时打印警告到 stderr，不崩溃

### `scripts/build_failure_skeleton.py`
作用：
- 读取 `case.runs.json`
- 找出 `final_status` 为 `fail` / `error` 的 case
- 将失败骨架写入 `report.md` 的标记区间

要求：
- 只能替换 `<!-- FAILURE_SKELETON_BEGIN -->` 与 `<!-- FAILURE_SKELETON_END -->` 之间的内容
- 不得删除、合并、降级失败 case
- 必须在 stderr 打印插入行数

## 反面清单

不要做这些事：
- 不要在 SKILL.md 里写死某个具体业务的测试样例
- 不要在模板里预置 action 名、case 名、原则名以外的占位业务文案
- 不要把原则改写成“提问检查表”
- 不要把业务判断逻辑写进脚本
- 不要引入第三方依赖
- 不要把本 skill 做成 Python 包
- 不要对 skill 自动评分或加权平均
- 不要把找不到 action 的情况跳过并沉默

## 最终目标

SkillLens 的目标不是“跑出一个分数”，而是：
- 为任意 skill 提供一套可复用的评测方法
- 让可测面、风险面、失败面都显式可见
- 让人类能基于结构化证据做最终判断
