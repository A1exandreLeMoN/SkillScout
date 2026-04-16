---
name: skill-test-runner
description: 面向 ToC 业务 skill 的通用测试执行 skill。统一做 apikey 检查、在线调用、结果归档、基础判定，并输出可复用的测评证据。使用场景：「帮我测试xxx skill」「跑一下xxx的测试用例」「测试skill并生成报告」。
version: 1.0.0
---

# 测试 Skill（skill-test-runner）

## 能力
- 检查 `TTFUND_APIKEY`
- 调用统一网关 `/openapi/skill/invoke`
- 支持任意 `skill_id` + `_skill_version`
- 固化最小证据输出（请求、响应、耗时、HTTP状态）
- 覆盖常见错误场景并给出友好提示

## 执行流程（Step by Step）

### Step 1: 环境检查
- 检查环境变量 `TTFUND_APIKEY` 是否存在
- 若缺失，**立即中断**并提示：
  ```
  当前未检测到本地环境变量 TTFUND_APIKEY，请先前往天天基金搜索 skills 获取 apikey，并在本机配置环境变量后再继续使用。
  获取路径：天天基金 App → 搜索「skills」→ 找到对应 skill 页面
  ```
- 若存在，记录（不输出完整值，仅记录长度用于日志）

### Step 2: 参数校验
- 确认 `skill_id` 和 `_skill_version` 均已提供
- 若缺失任一参数，提示缺失项并要求补充
- 校验 PayloadFile 路径是否存在（若提供）

### Step 3: 构造请求
- URL: `https://futurelabs-test.1234567.com.cn/ai-smart-skill-service/openapi/skill/invoke`
- Method: POST
- Headers:
  - `X-API-Key`: `$env:TTFUND_APIKEY`
  - `Content-Type`: `application/json`
- Body:
  ```json
  {
    "skill_id": "<输入的skill_id>",
    "_skill_version": "<输入的_version>",
    ...<payload内容>
  }
  ```

### Step 4: 发送请求
- 记录请求发送时间
- 记录 elapsed_ms（耗时）
- 记录 HTTP status code

### Step 5: 响应处理

#### 成功（2xx）
- 解析响应 JSON
- 输出 business_result（从 `data.raw_result.body` 提取）
- 输出 diagnostics（http_status, elapsed_ms, gateway_code）

#### HTTP 非 2xx
- 输出错误提示：「请求失败，HTTP 状态码: {code}」
- 不尝试解析 body 为业务结果

#### 网络错误（超时/连接失败）
- 输出错误提示：「网络错误，请检查网络连接或 API 服务状态」
- 记录错误类型

#### 响应体包含 error/detail
- 提取 `detail` 或 `error` 字段输出
- 判断是否为版本相关错误（version_info.is_outdated）

### Step 6: 结果解释顺序
1. 业务结果（business_result）
2. version_info 检查（若存在）
3. 升级建议（若 version_info.is_outdated = true）

## 强制规则
1. 调用前必须检查 `TTFUND_APIKEY`，缺失时**不得跳过**
2. 缺失时必须提示完整获取路径
3. 每次请求都必须带 `skill_id` 与 `_skill_version`
4. HTTP 状态码非 2xx 时，不尝试将错误体当成功结果解析
5. 若响应包含 `version_info.is_outdated = true`，先完成本次结果，再提示升级

## 检查点（用户确认）
- 调用前展示即将发送的请求摘要（skill_id、version、action），等待用户确认再发送
- 若用户未确认，不执行调用

## 使用方式

### 方式一：PowerShell 脚本
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke_test_skill.ps1 `
  -SkillId 'FUND_FAVOR_ZX' `
  -SkillVersion '1.0.0' `
  -PayloadFile '.\payload.sample.json'
```

### 方式二：直接调用（Skill 内部使用）
用户提供以下信息即可执行测试：
- `skill_id`：被测 skill 的 ID
- `_skill_version`：被测 skill 的版本
- `action`：要调用的 action 名称（如 subacc_list）
- `params`：要传递的参数对象

## 输出格式

### 标准输出结构
```
【测试执行报告】

■ 基本信息
  Skill ID: {skill_id}
  Version:   {_skill_version}
  耗时:      {elapsed_ms}ms
  HTTP状态:  {http_status}

■ 请求详情
  URL: https://futurelabs-test.1234567.com.cn/ai-smart-skill-service/openapi/skill/invoke
  Method: POST

■ 业务结果
  {business_result 格式化输出}

■ 诊断信息
  http_status: {code}
  elapsed_ms: {ms}
  gateway_code: {gateway_code}

■ 版本信息（若有）
  {version_info}
```

### 错误情况输出
```
【测试执行报告】

■ 基本信息
  Skill ID: {skill_id}
  Version:   {_skill_version}
  耗时:      {elapsed_ms}ms
  HTTP状态:  {http_status}

■ 错误类型
  {网络错误 / HTTP错误 / 业务错误 / 版本过旧}

■ 错误信息
  {detail 或 error_message}

■ 建议
  {对应建议}
```

## 输出结构建议
- `business_result`：核心业务数据
- `explanation_document`：关键字段说明
- `diagnostics`：{http_status, elapsed_ms, gateway_code}
- `error_info`（若有）：错误类型和详情

## 边界条件

| 场景 | 处理方式 |
|----|--------|
| TTFUND_APIKEY 未配置 | 提示获取路径，中断 |
| skill_id 缺失 | 提示必填参数，中断 |
| _skill_version 缺失 | 提示必填参数，中断 |
| PayloadFile 路径不存在 | 提示文件不存在，中断 |
| HTTP 超时（>30s） | 提示超时，附 retry 建议 |
| HTTP 非 2xx | 输出错误码和错误体 |
| 响应 body 解析失败 | 输出原始响应内容 |
| 版本过旧 | 先输出结果，再提示升级 |
