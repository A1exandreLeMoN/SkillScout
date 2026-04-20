# Changelog

## 2026-04-16

### Added

- 通用 Skill 测试框架骨架
- `skill-profile.template.json` 技能画像模板
- `action_schema`：统一 action 必填字段、推荐字段与变体命名
- `adapter` 层：当前默认实现为 `http_json`
- 自动生成 case
- 能力覆盖、Action 覆盖与风险覆盖统计
- 中文决策型报告输出
- GitHub 首页说明 `README.md`

### Improved

- runner 不再依赖固定数量的 case
- profile / adapter / runner 职责分离
- 请求与响应映射改为配置驱动
- 报告增加 schema、adapter 与覆盖缺口摘要

### Verified

- PowerShell 语法检查通过
- 本地 HTTP 假服务端到端执行通过
- 自动生成 case、覆盖统计与报告输出通过

