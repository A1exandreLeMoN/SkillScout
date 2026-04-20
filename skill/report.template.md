# <SKILL_ID> v<VERSION> 测评报告

## 1. 标题与元信息
- Skill 名称：
- Skill 版本：
- 测评日期：
- 测评环境：
- Profile 文件：
- 用例矩阵：
- Schema 版本：
- Profile 类型：
- Adapter 类型：
- Adapter 名称：
- 用例总数：<自动统计>
- 覆盖完整性：<待计算>
- 自动生成用例数：<自动统计>
- 手工补充用例数：<自动统计>
- 已执行用例数：<自动统计>
- 通过：<自动统计>
- 失败：<自动统计>
- 需复核：<自动统计>
- 跳过：<自动统计>

## 2. 能力覆盖摘要
> 这部分以 profile 声明的能力为准，不看固定条数。

| 能力标签 | 是否覆盖 | 命中用例 | 备注 |
| --- | --- | --- | --- |
| 鉴权接入 |  |  |  |
| 核心流程 |  |  |  |
| 自然语言交互 |  |  |  |
| 边界与错误 |  |  |  |
| 多轮上下文 |  |  |  |
| 副作用确认 |  |  |  |

## 3. Action 覆盖摘要
> 这部分以 profile 声明的 action 为准，每个 action 都应至少有一条 case。

| Action ID | Action 名称 | 是否覆盖 | 命中用例 | 必测 | 风险 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| auth_missing | 缺少认证信息 |  |  | 是 | low |  |
| auth_invalid | 错误认证信息 |  |  | 是 | low |  |
| auth_success | 最小可用接入 |  |  | 是 | low |  |
| core_main_1 | 核心主流程 1 |  |  | 是 | medium |  |
| core_main_2 | 核心主流程 2 |  |  | 是 | medium |  |
| core_main_3 | 核心主流程 3 |  |  | 是 | medium |  |
| nl_overview | 概览/列表式回答 |  |  | 是 | low |  |
| nl_detail | 详情查询式回答 |  |  | 是 | low |  |
| nl_filter | 筛选/分组/排序 |  |  | 是 | low |  |
| nl_time | 时间维度问题 |  |  | 是 | low |  |
| nl_target | 指定对象检索 |  |  | 是 | low |  |
| nl_explain | 解释型回答 |  |  | 是 | low |  |
| nl_retry | 失败后重试 |  |  | 是 | low |  |
| nl_context | 多轮上下文延续 |  |  | 否 | low |  |
| version_missing | 缺少版本字段 |  |  | 是 | medium |  |
| version_invalid | 版本字段错误 |  |  | 是 | medium |  |
| param_missing | 缺少关键参数 |  |  | 是 | medium |  |
| param_invalid | 关键参数非法或越界 |  |  | 是 | medium |  |
| write_blocked | 写操作未确认 |  |  | 是 | high |  |
| write_confirmed | 写操作已确认 |  |  | 是 | high |  |

## 4. 风险覆盖摘要
| 风险标签 | 是否覆盖 | 命中用例 | 备注 |
| --- | --- | --- | --- |
| 只读 |  |  |  |
| 写操作 |  |  |  |
| 不可逆操作 |  |  |  |
| 外部副作用 |  |  |  |
| 参数越界 |  |  |  |
| 版本缺失 |  |  |  |

## 5. Case 生成情况
| 模式 | 数量 | 说明 |
| --- | ---: | --- |
| 自动生成 |  | 从 profile.actions / capabilities 派生 |
| 手工补充 |  | 从矩阵文件读取 |
| 合计 |  |  |

## 6. Case 执行明细
| Case ID | Action | Variant | HTTP | 判定 | 耗时(ms) |
| --- | --- | --- | ---: | --- | ---: |

## 7. 分层详细结果
按实际命中的层级列出：
- 场景 ID
- 覆盖标签
- 输入摘要
- 预期
- 实际判定
- 关键发现

## 8. Bug 清单
| BugID | 触发输入（示例） | 实际返回 | 这是什么意思（用户可读说明） | 严重级别 | 归属层 | 用户影响 | 如何复现 | 建议修复 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

> 如果没有明确 Bug，也不要强行编造。可以写“无明确 Bug”。

## 9. Bug 统计
| 类别 | 数量 | 备注 |
| --- | ---: | --- |
| 高 |  |  |
| 中 |  |  |
| 低 |  |  |
| 未分类 |  |  |

## 10. 结论建议
- 是否通过：<Pass / Conditional Pass / Partial / Fail>
- 建议上线与否：<是 / 否 / 有条件>
- 需要修复的 P0：<列表>
- 需要修复的 P1：<列表>
- 可接受风险：<列表>

## 11. 附录
- Request / Response 摘要
- Profile 摘要
- Schema 摘要
- Adapter 摘要
- Matrix 摘要
- 关键错误码
- Action 覆盖摘要
- Case 生成摘要
- 覆盖与断言规则
- case.runs.json
- action.catalog.json
