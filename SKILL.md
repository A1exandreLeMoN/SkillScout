---
name: skill-test-runner
description: 面向 ToC 业务 skill 的通用测试执行 skill。统一做 apikey 检查、在线调用、结果归档、基础判定，并输出可复用的测评证据。
version: 1.0.0
---

# 测试 Skill（skill-test-runner）

## 能力
- 检查 `TTFUND_APIKEY`
- 调用统一网关 `/openapi/skill/invoke`
- 支持任意 `skill_id` + `_skill_version`
- 固化最小证据输出（请求、响应、耗时、HTTP状态）

## 强制规则
1. 调用前必须检查 `TTFUND_APIKEY`。
2. 缺失时必须提示：
   - `当前未检测到本地环境变量 TTFUND_APIKEY，请先前往天天基金搜索 skills 获取 apikey，并在本机配置环境变量后再继续使用。`
3. 每次请求都必须带 `skill_id` 与 `_skill_version`。
4. 结果解释顺序：业务结果 -> version_info -> 是否升级建议。

## 使用方式
- 脚本：`invoke_test_skill.ps1`
- 示例：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke_test_skill.ps1 `
  -SkillId 'FUND_FAVOR_ZX' `
  -SkillVersion '1.0.0' `
  -PayloadFile '.\payload.sample.json'
```

## 输出结构建议
- `business_result`
- `explanation_document`
- `diagnostics`（http_status, elapsed_ms, gateway_code）
