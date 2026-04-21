# SkillLens

SkillLens 是一个面向任意 Skill 的通用自动化测评框架，支持：

- 根据 Skill Profile 自动发现目标
- 按能力、Action、风险自动生成用例
- 执行 HTTP/JSON 型 Skill 测试
- 输出中文结构化报告与产物
- 将**执行健康**与**覆盖完整性**分开判定

> 核心原则：**覆盖率不等于通过。只要存在未解释的执行层错误，报告就必须显式标记为执行健康受损。**

## 目录结构

- `README.md`：项目说明
- `CHANGELOG.md`：发布记录
- `skill/`：Skill 运行所需的全部资产

## 这个项目能做什么

- 读取 `skill/skill-profile.template.json`
- 按 profile 自动生成测试用例
- 合并手工用例矩阵
- 批量执行测试
- 统计能力覆盖、Action 覆盖、风险覆盖
- 单独统计执行错误、传输错误、HTTP 错误、无响应错误
- 输出中文报告与机器可消费产物

## 核心结构

- **Profile**：描述 Skill 的输入、输出、能力、Action、风险和默认策略
- **Adapter**：描述 Skill 如何被执行、输入输出如何映射
- **Runner**：负责执行、判定、落盘
- **Report**：负责把结果讲清楚，尤其是执行健康

## 当前支持的 Adapter

### `http_json`

适用于：

- HTTP 网关型 Skill
- JSON 请求 / 响应型 Skill
- 具备 `action / capability / risk` 描述的 Skill

## 仓库文件说明

- `skill/invoke_test_skill.ps1`：核心 runner
- `skill/skill-profile.template.json`：Skill profile 模板
- `skill/test-case-matrix.template.json`：用例矩阵模板
- `skill/report.template.md`：报告模板
- `skill/SKILL.md`：Skill 本体说明
- `skill/payload.sample.json`：请求样例

## 快速开始

### 方式一：手动指定目标

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\skill\invoke_test_skill.ps1 `
  -SkillId "demo-skill" `
  -SkillVersion "1.0.0" `
  -PayloadFile ".\skill\payload.sample.json" `
  -ProfileFile ".\skill\skill-profile.template.json" `
  -CaseMatrixFile ".\skill\test-case-matrix.template.json" `
  -GatewayUrl "http://127.0.0.1:8080/run" `
  -AuthEnv "AUTH_TOKEN" `
  -SensitiveMode "always_allow"
```

### 方式二：自然语言发现目标

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\skill\invoke_test_skill.ps1 `
  -TargetQuery "测试一下这个 skill" `
  -TargetRoot "." `
  -SensitiveMode "always_allow"
```

## 输出产物

默认会在临时目录下生成产物，例如：

- `cases.json`
- `case.runs.json`
- `coverage.summary.json`
- `action.coverage.json`
- `case.plan.json`
- `profile.resolved.json`
- `matrix.resolved.json`
- `report.md`

## 覆盖与判定原则

SkillLens 不再用固定条数衡量完整性，而是看以下维度：

- 能力覆盖
- Action 覆盖
- 风险覆盖
- 执行健康

### 重要说明

- 覆盖完整不代表执行成功
- 只要出现执行层错误，必须在报告里显式展示
- 执行健康受损时，最终结论不得被覆盖率掩盖

## 当前状态

当前仓库已经完成：

- profile/schema 收口
- Action 级覆盖
- 自动 case 生成
- `http_json` adapter
- 自然语言目标发现
- 执行健康优先的报告契约

如果后续要支持更多 Skill 形态，只需要继续新增 adapter，而不要把业务逻辑继续堆进 runner。
