---
name: SkillLens
description: 通用 Skill 测试执行器。采用 profile + 用例矩阵 + runner 的方式执行联调、核心能力、自然语言交互与风险测试，并输出中文结构化证据与报告。
version: 3.1.0
triggers:
  - "测试 skill"
  - "skill 测试"
  - "run skill test"
  - "生成测试报告"
  - "按框架评测"
---

# 通用 Skill 测试执行器

## 1. 定位
这是一个面向任意 skill 的通用测试框架，而不是某个固定业务的专用脚本。

框架遵循四层结构：
- **Skill Profile**：技能画像，描述 skill 的输入、输出、风险与默认策略
- **Test Matrix**：用例矩阵，描述要测什么
- **Runner**：执行器，只负责加载、注入、请求、解析、判定和落盘
- **Report**：报告模板，只负责把结果讲清楚

运行时行为：
- 优先读取 profile.actions / capabilities 自动生成基础用例
- 如果提供了手工矩阵，则自动补齐缺失的 action / 能力覆盖
- 最终以自动生成 + 手工补充的有效用例集进行执行与判定
- 如果传入 `TargetQuery`，可在工作区中自动发现最匹配的 skill 目录与 profile

核心原则：
- 中文输出
- 配置优先，代码兜底
- 业务无关，不写死领域词
- 风险策略可覆盖，默认保守
- 能抽象的字段不写死
- 不以固定数量衡量完整性
- 以能力覆盖、action 覆盖和风险覆盖作为完整性标准

## 2. 这个 skill 适合做什么
适合评测以下类型的 skill：
- API 类 skill
- 多轮问答类 skill
- 带写操作或副作用的 skill
- 有版本字段、身份字段、风险字段的 skill
- 需要生成结构化证据与上线建议的 skill

## 3. 不要再写死的东西
未来扩展时，尽量不要把下面内容直接写进规则：
- 环境变量名
- 网关 URL
- Header 名
- skill_id / version 字段名
- action 列表
- 敏感动作列表
- 响应字段路径
- 报告中的业务术语
- 固定用例总数

这些都应该下沉到 profile 或配置文件里。

## 4. 推荐的配置层

### 4.1 Skill Profile
建议每个被测 skill 提供一份 profile，用来描述自己。

建议字段：
- `schema_version`
- `profile_kind`
- `adapter.kind`
- `adapter.name`
- `adapter.description`
- `adapter.supported_skill_shapes`
- `adapter.request_mapping`
- `adapter.response_mapping`
- `skill_id`
- `skill_version`
- `capabilities`
- `coverage_policy.require_all_capabilities`
- `coverage_policy.require_all_actions`
- `actions`
- `coverage_policy.required_tags`
- `coverage_policy.optional_tags`
- `transport.gateway_url`
- `transport.auth_env`
- `transport.auth_header`
- `transport.auth_prefix`
- `fields.skill_id`
- `fields.skill_version`
- `field_injection.enabled`
- `risk.default_mode`
- `risk.confirm_flag_fields`
- `risk.intent_fields`
- `risk.sensitive_keywords`
- `request_mapping.prompt_paths`
- `request_mapping.action_paths`
- `request_mapping.context_paths`
- `request_mapping.case_id_paths`
- `request_mapping.variant_paths`
- `request_mapping.coverage_paths`
- `request_mapping.metadata_path`
- `response_mapping.gateway_code_paths`
- `response_mapping.message_paths`
- `response_mapping.result_paths`
- `response_mapping.version_paths`
- `action_schema.required_fields`
- `action_schema.recommended_fields`
- `action_schema.variant_names`

每个 `actions[]` 项建议统一带齐以下基础字段，即使部分字段为空也要显式声明：
- `action_id`
- `label`
- `required`
- `risk`
- `coverage_tags`
- `preconditions`
- `assertions`
- `negative_assertions`
- `expected_http_status_in`
- `expected_gateway_code_in`
- `response_contains`
- `response_not_contains`
- `variants`
- `input_hints`

这样 runner、生成器和报告就能用同一套字段表述 action，而不用再为不同 skill 猜字段形状。

### 4.2 Adapter
Adapter 用来描述“这个 skill 通过什么方式被执行、输入和输出如何解释”。

当前 runner 已实现的默认适配器是：
- `http_json`

它适合：
- HTTP 网关
- JSON 请求 / 响应
- 带鉴权头的远程 skill

未来如果要支持其他形态，可以继续沿用同一个 profile 结构，只替换 `adapter.kind` 和适配规则。

### 4.3 Test Matrix
用例矩阵负责描述“测试什么”，而不是“怎么发请求”。

默认覆盖建议是**能力驱动**，而不是**数量驱动**：
- 先列出 skill 声明的能力标签
- 再为每个能力至少安排 1 条可执行用例
- 再为每个 action 至少安排 1 条可执行用例
- 再补足风险、错误、上下文、多轮和边界场景
- 不要求固定总数，但要求覆盖到 profile 声明的所有必测能力与必测 action

### 4.4 Runner
Runner 只做执行层工作：
1. 读取 profile
2. 读取 payload / case matrix
3. 注入身份字段
4. 判断是否为敏感请求
5. 根据策略决定是否确认
6. 发请求并记录耗时
7. 解析响应并生成结构化结果
8. 输出 artifacts 与 report
9. 计算覆盖完整性，检查是否命中 profile 声明的能力标签与 action

## 5. 执行器参数
脚本：`invoke_test_skill.ps1`

推荐参数：
- `SkillId`
- `SkillVersion`
- `PayloadFile`
- `ProfileFile`
- `CaseMatrixFile`
- `GatewayUrl`
- `AuthEnv`
- `AuthHeader`
- `AuthPrefix`
- `SkillIdField`
- `SkillVersionField`
- `DisableFieldInjection`
- `SensitiveMode`
- `Pretty`
- `TargetQuery`
- `TargetRoot`
- `DiscoverTargetSkill`

传入 `TargetQuery` 时，框架会先扫描工作区，自动发现最匹配的 skill，并回填 profile / payload / matrix / 输出目录。

## 6. 运行原则
1. 优先读 profile，再读命令行参数，再用框架默认值。
2. 如果提供了 `TargetQuery`，先尝试自动发现对应 skill，再回填 profile / payload / matrix。
3. 缺少网关地址或认证信息时，明确报错并停止。
4. 写操作默认走确认流程，不要默认放行。
5. 响应结构不假设固定字段，通过 response_mapping 解析。
6. 非 2xx 也要输出结构化 error_info。
7. 报告里要区分：业务问题、配置问题、runner 问题。
8. 最终是否完整，不看条数，只看 profile 声明的能力是否被覆盖。

## 7. 输出产物
至少输出以下结果：
- `artifacts/cases.json`
- `artifacts/real-conversation-replay.json`
- `report.md`
- `artifacts/case.runs.json`
- `artifacts/action.catalog.json`

建议额外输出：
- `artifacts/profile.resolved.json`
- `artifacts/matrix.resolved.json`
- `artifacts/request.log.json`
- `artifacts/coverage.summary.json`
- `artifacts/action.coverage.json`
- `artifacts/case.plan.json`
- `artifacts/case.runs.json`
- `artifacts/action.catalog.json`

## 8. 判定标准
### 8.1 单条用例
- `Pass`
- `Fail`
- `Partial`

### 8.2 最终评级
- `Pass`
- `Conditional Pass`
- `Partial`
- `Fail`

建议解释口径：
- 主流程不可用 或 高风险误导：`Fail`
- 主流程可用，但风险未闭环：`Conditional Pass`
- 覆盖不完整，但核心路径基本通：`Partial`
- profile 声明的必测能力存在缺口：至少 `Partial`
- profile 声明的必测 action 存在缺口：至少 `Partial`
- profile 声明的必测能力全部覆盖，且高风险项已闭环：优先 `Pass`
- profile 声明的必测 action 全部覆盖，且高风险项已闭环：优先 `Pass`

## 9. 默认测试模板
默认测试模板是通用骨架，不绑定具体行业。

模板目标不是固定几条，而是覆盖这些维度：
- 认证 / 接入
- 核心流程
- 能力标签逐项覆盖
- 自然语言理解 / 解释
- 错误恢复
- 风险与边界
- 多轮上下文
- 副作用确认
- 结果一致性
- 自动生成的基础用例

## 10. 适配建议
如果某个 skill 不是 HTTP API，而是：
- 本地命令
- 文件生成
- 工具调用
- 多轮对话

也可以继续沿用这个框架，但需要在 profile 里补齐：
- 输入形式
- 输出映射
- 风险策略
- 结果判定方式
- 能力标签与覆盖要求

## 11. 示例
推荐的执行方式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke_test_skill.ps1 `
  -SkillId 'EXAMPLE_SKILL' `
  -SkillVersion '1.0.0' `
  -ProfileFile '.\skill-profile.template.json' `
  -PayloadFile '.\payload.sample.json' `
  -Pretty
```

## 12. 设计约束
- 不要把 skill 只做成“某个业务接口测试器”
- 不要把 action、字段名、错误码写死在 runner 中
- 不要让报告只适配一种场景
- 不要把中文输出和业务词混在一起
- 不要回到按固定条数验收的方式
- 不要回到只看能力、不看 action 的方式

目标是：一套框架，能评测不同类型的 skill，并且能证明覆盖到了它声明的能力与 action。
