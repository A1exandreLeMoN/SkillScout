param(
  [Parameter(Mandatory=$true)]
  [string]$SkillId,

  [Parameter(Mandatory=$false)]
  [string]$SkillVersion = '1.0.0',

  [Parameter(Mandatory=$false)]
  [string]$PayloadFile = "$PSScriptRoot/payload.sample.json",

  [Parameter(Mandatory=$false)]
  [string]$GatewayUrl = 'https://futurelabs-test.1234567.com.cn/ai-smart-skill-service/openapi/skill/invoke',

  [switch]$Pretty
)

$apiKey = $env:TTFUND_APIKEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  Write-Host "当前未检测到本地环境变量 TTFUND_APIKEY，请先前往天天基金搜索 skills 获取 apikey，并在本机配置环境变量后再继续使用。"
  exit 1
}

if (-not (Test-Path -LiteralPath $PayloadFile)) {
  Write-Host "未找到请求文件: $PayloadFile"
  exit 1
}

try {
  $payloadObj = Get-Content -LiteralPath $PayloadFile -Raw | ConvertFrom-Json
} catch {
  Write-Host "请求体 JSON 解析失败，请检查 payload 文件格式。"
  exit 1
}

$payloadObj.skill_id = $SkillId
$payloadObj._skill_version = $SkillVersion

$headers = @{
  'X-API-Key' = $apiKey
  'Content-Type' = 'application/json'
}

$body = $payloadObj | ConvertTo-Json -Depth 100
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
  $resp = Invoke-WebRequest -Uri $GatewayUrl -Method Post -Headers $headers -Body $body -TimeoutSec 60
  $sw.Stop()
  $httpStatus = [int]$resp.StatusCode
  $obj = $resp.Content | ConvertFrom-Json -Depth 100

  $out = [ordered]@{
    diagnostics = [ordered]@{
      http_status = $httpStatus
      elapsed_ms = [int]$sw.ElapsedMilliseconds
      gateway_code = $obj.code
      message = $obj.message
    }
    business_result = $obj.data.raw_result.body
    explanation_document = [ordered]@{
      summary = '先看业务结果，再看版本信息，最后决定是否追加升级建议。'
      version_info = $obj.data.version_info
    }
  }

  if ($Pretty) {
    $out | ConvertTo-Json -Depth 100
  } else {
    $out
  }
} catch {
  $sw.Stop()
  if ($_.Exception.Response) {
    $status = [int]$_.Exception.Response.StatusCode.value__
    Write-Host ("调用失败，HTTP状态: {0}，elapsed_ms: {1}" -f $status, [int]$sw.ElapsedMilliseconds)
  } else {
    Write-Host ("调用失败: {0}" -f $_.Exception.Message)
  }
  exit 1
}
