# SkillTest-Skill

一个面向任意 Skill 的通用自动化测评框架。  
当前实现以 `http_json` 适配器为默认执行模式，适合测试通过 HTTP 网关提供能力、并以 JSON 交换请求/响应的 Skill。

## 这个项目能做什么

- 读取 `skill-profile.template.json`
- 按 profile 自动生成测试用例
- 合并手工用例矩阵
- 执行批量测试
- 统计能力覆盖、Action 覆盖和风险覆盖
- 输出中文结构化报告与产物

## 核心理念

- **profile 负责描述 Skill**
- **adapter 负责描述怎么执行这种 Skill**
- **runner 负责通用执行、判定和落盘**

这样可以把“业务描述”和“测试逻辑”分开，后续更容易适配不同类型的 Skill。

## 当前支持的适配器

### `http_json`

当前默认适配器，适用于：

- HTTP 网关
- JSON 请求 / 响应
- 带鉴权头的远程 Skill
- 具备 `action / capability / risk` 描述的 Skill

## 仓库文件说明

- `invoke_test_skill.ps1`：核心 runner
- `skill-profile.template.json`：技能画像模板
- `test-case-matrix.template.json`：用例矩阵模板
- `report.template.md`：报告模板
- `SKILL.md`：Skill 本体说明
- `payload.sample.json`：请求样例

## 快速开始

1. 准备一个被测 Skill 的 profile
2. 准备基础 payload
3. 配置 `GatewayUrl` 和认证环境变量
4. 执行 `invoke_test_skill.ps1`
5. 查看 `report.md` 和 artifacts 产物

示例：

```powershell
.\invoke_test_skill.ps1 `
  -SkillId "demo-skill" `
  -SkillVersion "1.0.0" `
  -PayloadFile ".\payload.sample.json" `
  -ProfileFile ".\skill-profile.template.json" `
  -CaseMatrixFile ".\test-case-matrix.template.json" `
  -GatewayUrl "http://127.0.0.1:8080/run" `
  -ApiKeyEnv "API_KEY" `
  -SensitiveMode "always_allow"
```

## 输出内容

运行后会生成一组中文可读、机器可消费的产物，例如：

- `cases.json`
- `case.runs.json`
- `coverage.summary.json`
- `action.coverage.json`
- `case.plan.json`
- `profile.resolved.json`
- `matrix.resolved.json`
- `report.md`

## 覆盖原则

当前不是按固定数量验收，而是按以下维度判断完整性：

- 能力覆盖
- Action 覆盖
- 风险覆盖
- 必测项是否闭环

## 当前状态

当前仓库已经完成：

- profile/schema 收口
- Action 级覆盖
- 自动 case 生成
- `http_json` 适配器
- 中文报告输出
- 本地端到端验证

后续如果要扩展到更多 Skill 形态，可以继续增加新的 adapter，而不是把逻辑堆进 runner 里。

