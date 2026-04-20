param(
  [Parameter(Mandatory = $false)]
  [string]$SkillId,

  [Parameter(Mandatory = $false)]
  [string]$SkillVersion,

  [Parameter(Mandatory = $false)]
  [string]$PayloadFile,

  [Parameter(Mandatory = $false)]
  [string]$ProfileFile,

  [Parameter(Mandatory = $false)]
  [string]$CaseMatrixFile,

  [Parameter(Mandatory = $false)]
  [string]$GatewayUrl,

  [Parameter(Mandatory = $false)]
  [string]$ApiKeyEnv,

  [Parameter(Mandatory = $false)]
  [string]$ApiKeyHeader,

  [Parameter(Mandatory = $false)]
  [string]$ApiKeyPrefix,

  [Parameter(Mandatory = $false)]
  [string]$SkillIdField,

  [Parameter(Mandatory = $false)]
  [string]$SkillVersionField,

  [Parameter(Mandatory = $false)]
  [ValidateSet('ask', 'always_allow', 'always_block')]
  [string]$SensitiveMode,

  [Parameter(Mandatory = $false)]
  [string]$OutputDir,

  [Parameter(Mandatory = $false)]
  [string]$TargetQuery,

  [Parameter(Mandatory = $false)]
  [string]$TargetRoot,

  [switch]$DiscoverTargetSkill,

  [switch]$DisableFieldInjection,
  [switch]$Pretty
)

if ([string]::IsNullOrWhiteSpace($SkillVersion)) {
  $SkillVersion = '1.0.0'
}
if ([string]::IsNullOrWhiteSpace($PayloadFile)) {
  $PayloadFile = Join-Path $PSScriptRoot 'payload.sample.json'
}
if ([string]::IsNullOrWhiteSpace($ProfileFile)) {
  $ProfileFile = Join-Path $PSScriptRoot 'skill-profile.template.json'
}
if ([string]::IsNullOrWhiteSpace($CaseMatrixFile)) {
  $CaseMatrixFile = Join-Path $PSScriptRoot 'test-case-matrix.template.json'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) 'skillscout-artifacts'
}
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot = Split-Path -Path $PSScriptRoot -Parent
}

function Set-OrAddProperty {
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$Value
  )
  $prop = $Obj.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  } else {
    $Obj.$Name = $Value
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  try {
    $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
    try {
      $text = $reader.ReadToEnd()
    } finally {
      $reader.Close()
      $reader.Dispose()
    }
    return ($text | ConvertFrom-Json)
  } catch {
    $detail = $null
    try {
      $detail = $_.Exception.Message
    } catch {
      $detail = $null
    }
    if ([string]::IsNullOrWhiteSpace($detail)) {
      throw ("JSON 文件解析失败: {0}" -f $Path)
    }
    throw ("JSON 文件解析失败: {0} | {1}" -f $Path, $detail)
  }
}

function Normalize-SearchText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $normalized = $Text.ToLowerInvariant()
  $normalized = $normalized -replace '[^\p{L}\p{N}]+', ' '
  return (($normalized -replace '\s+', ' ').Trim())
}

function Get-SkillMarkdownFrontMatter {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{} }
  try {
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  } catch {
    return [ordered]@{}
  }

  if ($content -notmatch '(?s)^---\s*(.*?)\s*---') {
    return [ordered]@{}
  }

  $meta = [ordered]@{}
  foreach ($line in ($Matches[1] -split "`r?`n")) {
    if ($line -match '^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$') {
      $key = $matches[1]
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -ge 2) {
          $value = $value.Substring(1, $value.Length - 2)
        }
      }
      $meta[$key] = $value
    }
  }
  return $meta
}

function Get-TextMatchScore {
  param(
    [string]$Query,
    [string]$Candidate
  )
  $q = Normalize-SearchText -Text $Query
  $c = Normalize-SearchText -Text $Candidate
  if ([string]::IsNullOrWhiteSpace($q) -or [string]::IsNullOrWhiteSpace($c)) {
    return 0
  }

  $score = 0
  if ($c.Contains($q)) { $score += 100 }
  if ($q.Contains($c)) { $score += 40 }
  foreach ($term in ($q -split ' ')) {
    if ([string]::IsNullOrWhiteSpace($term)) { continue }
    if ($term.Length -lt 2) { continue }
    if ($c.Contains($term)) { $score += 10 }
  }
  return $score
}

function Resolve-SkillTarget {
  param(
    [string]$TargetQuery,
    [string]$WorkspaceRoot,
    [string]$CurrentSkillRoot
  )

  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot)) {
    return $null
  }

  $skillDocs = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue
  if ($null -eq $skillDocs -or $skillDocs.Count -eq 0) {
    return $null
  }

  $candidates = @()
  foreach ($doc in $skillDocs) {
    $skillDir = Split-Path -Path $doc.FullName -Parent
    $profileCandidates = @(
      (Join-Path $skillDir 'skill-profile.json'),
      (Join-Path $skillDir 'skill-profile.template.json'),
      (Join-Path $skillDir 'profile.json')
    )
    $profileFile = $profileCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$profileFile)) {
      continue
    }

    $frontMatter = Get-SkillMarkdownFrontMatter -Path $doc.FullName
    $profileObj = $null
    try {
      $profileObj = Read-JsonFile -Path $profileFile
    } catch {
      $profileObj = $null
    }

    $skillId = $null
    if ($null -ne $profileObj) {
      $skillId = [string](Get-NestedValue -Obj $profileObj -Path 'skill_id')
    }

    $skillVersion = $null
    if ($null -ne $profileObj) {
      $skillVersion = [string](Get-NestedValue -Obj $profileObj -Path 'skill_version')
    }

    $skillName = [IO.Path]::GetFileName($skillDir)
    if ($frontMatter.Contains('name')) {
      $skillName = [string]$frontMatter['name']
    }

    $description = ''
    if ($frontMatter.Contains('description')) {
      $description = [string]$frontMatter['description']
    }

    $candidateText = @([IO.Path]::GetFileName($skillDir), $skillName, $description, $skillId, $skillVersion) -join ' '
    $score = Get-TextMatchScore -Query $TargetQuery -Candidate $candidateText
    if ($skillDir -eq $CurrentSkillRoot) {
      $score += 50
    }

    $payloadCandidate = Join-Path $skillDir 'payload.sample.json'
    $caseMatrixCandidate = Join-Path $skillDir 'test-case-matrix.template.json'
    $payloadFile = $null
    if (Test-Path -LiteralPath $payloadCandidate) {
      $payloadFile = $payloadCandidate
    }

    $caseMatrixFile = $null
    if (Test-Path -LiteralPath $caseMatrixCandidate) {
      $caseMatrixFile = $caseMatrixCandidate
    }

    $adapterKind = $null
    if ($null -ne $profileObj) {
      $adapterKind = [string](Get-NestedValue -Obj $profileObj -Path 'adapter.kind')
    }

    $candidates += [ordered]@{
      skill_directory = $skillDir
      skill_markdown = $doc.FullName
      profile_file = $profileFile
      payload_file = $payloadFile
      case_matrix_file = $caseMatrixFile
      skill_id = $skillId
      skill_version = $skillVersion
      skill_name = $skillName
      description = $description
      adapter_kind = $adapterKind
      score = $score
    }
  }

  if ($candidates.Count -eq 0) {
    return $null
  }

  return @(
    $candidates |
      Sort-Object @{Expression = 'score'; Descending = $true}, @{Expression = 'skill_directory'; Descending = $false} |
      Select-Object -First 1
  )
}

function Validate-ProfileSchema {
  param([object]$Profile)

  if ($null -eq $Profile) {
    throw 'Profile 不能为空。请提供有效的 skill profile。'
  }

  $schemaVersion = [string](Get-NestedValue -Obj $Profile -Path 'schema_version')
  if ([string]::IsNullOrWhiteSpace($schemaVersion)) {
    throw 'Profile 缺少 schema_version。请显式声明 profile schema 版本。'
  }

  $profileKind = [string](Get-NestedValue -Obj $Profile -Path 'profile_kind')
  if ([string]::IsNullOrWhiteSpace($profileKind)) {
    throw 'Profile 缺少 profile_kind。请显式声明 profile 类型。'
  }

  $adapterKind = [string](Get-AdapterKind -Profile $Profile)
  if ([string]::IsNullOrWhiteSpace($adapterKind)) {
    throw 'Profile 缺少 adapter.kind。请显式声明适配器类型。'
  }
  if ($adapterKind -ne 'http_json') {
    throw ("当前 runner 仅实现 http_json 适配器，检测到不支持的 adapter.kind: {0}" -f $adapterKind)
  }

  $actionSchemaRequired = @(Get-StringArray (Get-NestedValue -Obj $Profile -Path 'action_schema.required_fields'))
  if ($actionSchemaRequired.Count -eq 0) {
    throw 'Profile 缺少 action_schema.required_fields。请声明 action 的必填字段集合。'
  }

  $requiredActionFields = @($actionSchemaRequired | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($requiredActionFields.Count -eq 0) {
    throw 'Profile 的 action_schema.required_fields 为空。请至少声明 action_id、label、required、risk、coverage_tags。'
  }

  $actions = Get-ActionArray -Profile $Profile
  foreach ($action in $actions) {
    $actionId = [string](Get-ActionId -Action $action)
    if ([string]::IsNullOrWhiteSpace($actionId)) {
      $actionId = '<unknown>'
    }

    $missing = @()
    foreach ($field in $requiredActionFields) {
      $value = Get-NestedValue -Obj $action -Path $field
      if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        $missing += $field
      }
    }

    if ($missing.Count -gt 0) {
      throw ("Profile action '{0}' 缺少必填字段: {1}" -f $actionId, ($missing -join '、'))
    }
  }

  return $true
}

function Get-AdapterProfile {
  param([object]$Profile)

  $adapter = Get-NestedValue -Obj $Profile -Path 'adapter'
  if ($null -eq $adapter) {
    return [ordered]@{
      kind = 'http_json'
      name = 'HTTP JSON 网关适配器'
      description = '以 HTTP + JSON 形式执行 skill 测试。'
      supported_skill_shapes = @('api', 'dialogue', 'workflow', 'tool')
      request_mapping = Get-NestedValue -Obj $Profile -Path 'request_mapping'
      response_mapping = Get-NestedValue -Obj $Profile -Path 'response_mapping'
    }
  }

  $kind = [string](Get-NestedValue -Obj $adapter -Path 'kind')
  if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'http_json' }
  $name = [string](Get-NestedValue -Obj $adapter -Path 'name')
  if ([string]::IsNullOrWhiteSpace($name)) { $name = 'HTTP JSON 网关适配器' }
  $description = [string](Get-NestedValue -Obj $adapter -Path 'description')
  if ([string]::IsNullOrWhiteSpace($description)) { $description = '以 HTTP + JSON 形式执行 skill 测试。' }
  $supportedSkillShapes = @(Get-StringArray (Get-NestedValue -Obj $adapter -Path 'supported_skill_shapes') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($supportedSkillShapes.Count -eq 0) {
    $supportedSkillShapes = @('api', 'dialogue', 'workflow', 'tool')
  }

  return [ordered]@{
    kind = $kind
    name = $name
    description = $description
    supported_skill_shapes = @($supportedSkillShapes)
    request_mapping = Get-NestedValue -Obj $adapter -Path 'request_mapping'
    response_mapping = Get-NestedValue -Obj $adapter -Path 'response_mapping'
  }
}

function Get-AdapterKind {
  param([object]$Profile)
  return [string](Get-NestedValue -Obj (Get-AdapterProfile -Profile $Profile) -Path 'kind')
}

function Get-AdapterName {
  param([object]$Profile)
  return [string](Get-NestedValue -Obj (Get-AdapterProfile -Profile $Profile) -Path 'name')
}

function Get-AdapterSupportedSkillShapes {
  param([object]$Profile)
  return @(Get-StringArray (Get-NestedValue -Obj (Get-AdapterProfile -Profile $Profile) -Path 'supported_skill_shapes') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Resolve-Value {
  param(
    [object]$Primary,
    [object]$Secondary,
    [object]$Fallback
  )
  if (-not [string]::IsNullOrWhiteSpace([string]$Primary)) { return $Primary }
  if (-not [string]::IsNullOrWhiteSpace([string]$Secondary)) { return $Secondary }
  return $Fallback
}

function Get-StringArray {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Array]) { return @($Value | ForEach-Object { [string]$_ }) }
  return @([string]$Value)
}

function Test-Truthy {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return [bool]$Value }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  return @('1', 'true', 'yes', 'y', 'on') -contains $text.ToLowerInvariant()
}

function Test-PropertyTruthy {
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $prop = $Obj.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $false }
  return Test-Truthy -Value $prop.Value
}

function Get-NestedValue {
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string]$Path
  )
  if ($null -eq $Obj -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
  $current = $Obj
  foreach ($segment in $Path.Split('.')) {
    if ($null -eq $current) { return $null }
    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($segment)) { return $null }
      $current = $current[$segment]
      continue
    }
    $prop = $current.PSObject.Properties[$segment]
    if ($null -eq $prop) { return $null }
    $current = $prop.Value
  }
  return $current
}

function Set-NestedValue {
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  if ($null -eq $Obj -or [string]::IsNullOrWhiteSpace($Path)) { return }

  $segments = $Path.Split('.')
  $current = $Obj
  for ($i = 0; $i -lt $segments.Length - 1; $i++) {
    $segment = $segments[$i]
    if ($current -is [System.Collections.IDictionary]) {
      $next = if ($current.Contains($segment)) { $current[$segment] } else { $null }
      if ($null -eq $next) {
        $newNode = [ordered]@{}
        $current[$segment] = $newNode
        $current = $newNode
      } else {
        $current = $next
      }
      continue
    }
    $next = $current.PSObject.Properties[$segment]
    if ($null -eq $next -or $null -eq $next.Value) {
      $newNode = [ordered]@{}
      if ($null -eq $next) {
        $current | Add-Member -NotePropertyName $segment -NotePropertyValue $newNode
      } else {
        $current.$segment = $newNode
      }
      $current = $newNode
    } else {
      $current = $next.Value
    }
  }

  $leaf = $segments[$segments.Length - 1]
  if ($current -is [System.Collections.IDictionary]) {
    $current[$leaf] = $Value
    return
  }
  $prop = $current.PSObject.Properties[$leaf]
  if ($null -eq $prop) {
    $current | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value
  } else {
    $current.$leaf = $Value
  }
}

function Copy-DeepObject {
  param([Parameter(Mandatory = $true)]$Obj)
  if ($null -eq $Obj) { return $null }
  return ($Obj | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}

function Resolve-From-Paths {
  param(
    [object]$Obj,
    [string[]]$Paths
  )
  foreach ($path in $Paths) {
    $value = Get-NestedValue -Obj $Obj -Path $path
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
      return $value
    }
  }
  return $null
}

function Get-TruncatedText {
  param(
    [string]$Text,
    [int]$MaxLength = 500
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  if ($Text.Length -le $MaxLength) { return $Text }
  return ($Text.Substring(0, $MaxLength) + '…')
}

function Parse-ResponseText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try {
    return ($Text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Get-FriendlyErrorSummary {
  param(
    [int]$HttpStatus,
    [string]$RawText
  )

  $text = if ($RawText) { $RawText.ToLowerInvariant() } else { '' }

  if ($text -match 'timeout|timed out') {
    return [ordered]@{
      user_message = '请求超时。'
      explanation = '本次请求等待时间过长，服务端或网络链路可能不稳定。'
      suggestion = '缩小请求体或降低并发后重试；必要时提高超时时间。'
    }
  }

  if ($HttpStatus -eq 401) {
    return [ordered]@{
      user_message = '鉴权失败。'
      explanation = '认证信息无效、缺失或未授权访问该目标。'
      suggestion = '检查环境变量、Header 名称和密钥是否正确。'
    }
  }
  if ($HttpStatus -eq 403) {
    return [ordered]@{
      user_message = '权限不足。'
      explanation = '认证通过，但当前身份没有执行该操作的权限。'
      suggestion = '检查账号权限、资源范围或是否需要额外开通能力。'
    }
  }
  if ($HttpStatus -eq 404) {
    return [ordered]@{
      user_message = '目标地址不存在。'
      explanation = '网关路径、服务路由或目标环境可能配置错误。'
      suggestion = '核对 GatewayUrl 和环境配置。'
    }
  }
  if ($HttpStatus -eq 408) {
    return [ordered]@{
      user_message = '请求超时。'
      explanation = '服务端未在预期时间内返回响应。'
      suggestion = '重试一次，并检查后端处理耗时。'
    }
  }
  if ($HttpStatus -eq 413) {
    return [ordered]@{
      user_message = '请求体过大。'
      explanation = '当前 payload 可能超过网关或服务允许的大小。'
      suggestion = '缩小请求体，去掉无关上下文或附件。'
    }
  }
  if ($HttpStatus -eq 429) {
    return [ordered]@{
      user_message = '请求过于频繁。'
      explanation = '触发了限流策略。'
      suggestion = '降低频率后重试，或申请更高配额。'
    }
  }
  if ($HttpStatus -ge 500 -and $HttpStatus -lt 600) {
    return [ordered]@{
      user_message = '服务端异常。'
      explanation = '网关或后端服务出现错误。'
      suggestion = '记录请求和响应摘要，联系后端排查日志。'
    }
  }

  if ($HttpStatus -eq 400 -or $text -match 'validation|required|schema|invalid|missing') {
    return [ordered]@{
      user_message = '参数校验失败。'
      explanation = '请求结构、必填字段或字段值不符合接口要求。'
      suggestion = '核对必填字段、字段类型、枚举值和版本字段。'
    }
  }

  return [ordered]@{
    user_message = '请求失败。'
    explanation = '接口返回了错误，但当前信息不足以直接定位。'
    suggestion = '保留请求体、响应体和 profile 配置，继续缩小问题范围。'
  }
}

function Is-SensitivePayload {
  param(
    [Parameter(Mandatory = $true)]$PayloadObj,
    [object]$Profile
  )
  if ($null -eq $PayloadObj) { return $false }

  $confirmFields = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'risk.confirm_flag_fields')
  if ($confirmFields.Count -eq 0) {
    $confirmFields = @('confirm_write', 'requires_confirmation')
  }
  foreach ($field in $confirmFields) {
    if (Test-Truthy (Get-NestedValue -Obj $PayloadObj -Path $field)) {
      return $true
    }
    if (Test-PropertyTruthy -Obj $PayloadObj -Name $field) {
      return $true
    }
  }

  $intentFields = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'risk.intent_fields')
  if ($intentFields.Count -eq 0) {
    $intentFields = @('action', 'operation', 'intent', 'mode', 'type', 'risk')
  }

  $keywords = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'risk.sensitive_keywords')
  if ($keywords.Count -eq 0) {
    $keywords = @(
      'write',
      'update',
      'delete',
      'create',
      'publish',
      'submit',
      'approve',
      'reject',
      'execute',
      'invoke',
      'call',
      'cancel',
      'rollback'
    )
  }
  $keywordPattern = ($keywords | ForEach-Object { [regex]::Escape($_) }) -join '|'

  foreach ($field in $intentFields) {
    $value = Get-NestedValue -Obj $PayloadObj -Path $field
    if ($null -eq $value) { continue }
    $text = [string]$value
    if (-not [string]::IsNullOrWhiteSpace($text) -and $text -match $keywordPattern) {
      return $true
    }
  }

  return $false
}

function Get-CaseArray {
  param([object]$Matrix)
  if ($null -eq $Matrix) { return @() }
  if ($Matrix.PSObject.Properties['cases']) {
    return @($Matrix.cases)
  }
  if ($Matrix -is [System.Array]) {
    return @($Matrix)
  }
  return @()
}

function Get-CaseCoverageTags {
  param([object]$Case)
  $tags = @()
  if ($null -eq $Case) { return $tags }

  $caseTags = Get-StringArray (Get-NestedValue -Obj $Case -Path 'coverage_tags')
  if ($caseTags.Count -gt 0) {
    $tags += $caseTags
  }

  if ($tags.Count -eq 0) {
    $layer = Get-NestedValue -Obj $Case -Path 'layer'
    if (-not [string]::IsNullOrWhiteSpace([string]$layer)) {
      $tags += [string]$layer
    }
  }

  return @($tags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-CoverageSummary {
  param(
    [object]$Profile,
    [object]$Cases
  )

  $declaredCapabilities = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'capabilities')
  $requiredTags = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'coverage_policy.required_tags')
  $optionalTags = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'coverage_policy.optional_tags')
  $requireAll = Test-Truthy (Get-NestedValue -Obj $Profile -Path 'coverage_policy.require_all_capabilities')

  $targetTags = @()
  if ($declaredCapabilities.Count -gt 0) { $targetTags += $declaredCapabilities }
  if ($requiredTags.Count -gt 0) { $targetTags += $requiredTags }
  $targetTags = @($targetTags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

  $coverageMap = @{}
  foreach ($case in $cases) {
    $caseId = [string](Get-NestedValue -Obj $case -Path 'case_id')
    foreach ($tag in (Get-CaseCoverageTags -Case $case)) {
      if (-not $coverageMap.ContainsKey($tag)) {
        $coverageMap[$tag] = New-Object System.Collections.Generic.List[string]
      }
      if (-not [string]::IsNullOrWhiteSpace($caseId) -and -not $coverageMap[$tag].Contains($caseId)) {
        [void]$coverageMap[$tag].Add($caseId)
      }
    }
  }

  $coveredTags = @($coverageMap.Keys | Sort-Object -Unique)
  $missingRequiredTags = @($targetTags | Where-Object { $coveredTags -notcontains $_ })
  $coverageComplete = ($requireAll -and $missingRequiredTags.Count -eq 0) -or (-not $requireAll)

  $coverageDetails = foreach ($tag in $targetTags) {
    [ordered]@{
      tag = $tag
      covered = ($coveredTags -contains $tag)
      case_ids = if ($coverageMap.ContainsKey($tag)) { @($coverageMap[$tag]) } else { @() }
    }
  }

  [ordered]@{
    require_all_capabilities = $requireAll
    declared_capabilities = $declaredCapabilities
    required_tags = $requiredTags
    optional_tags = $optionalTags
    target_tags = $targetTags
    covered_tags = $coveredTags
    missing_required_tags = $missingRequiredTags
    coverage_complete = $coverageComplete
    case_count = $cases.Count
    details = @($coverageDetails)
  }
}

function Get-ActionArray {
  param([object]$Profile)
  $actions = Get-NestedValue -Obj $Profile -Path 'actions'
  if ($null -eq $actions) { return @() }
  if ($actions -is [System.Array]) { return @($actions) }
  return @($actions)
}

function Get-ActionId {
  param([object]$Action)
  if ($null -eq $Action) { return $null }
  $value = Get-NestedValue -Obj $Action -Path 'action_id'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  $value = Get-NestedValue -Obj $Action -Path 'name'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  return $null
}

function Get-ActionLabel {
  param([object]$Action)
  if ($null -eq $Action) { return $null }
  $value = Get-NestedValue -Obj $Action -Path 'label'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  $value = Get-ActionId -Action $Action
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  return $null
}

function Get-ActionRequired {
  param([object]$Action)
  if ($null -eq $Action) { return $false }
  return Test-Truthy (Get-NestedValue -Obj $Action -Path 'required')
}

function Get-ActionRisk {
  param([object]$Action)
  if ($null -eq $Action) { return $null }
  $value = Get-NestedValue -Obj $Action -Path 'risk'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  return $null
}

function Get-ActionCoverageTags {
  param([object]$Action)
  if ($null -eq $Action) { return @() }
  return @(Get-StringArray (Get-NestedValue -Obj $Action -Path 'coverage_tags') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-ActionPrompt {
  param([object]$Action)
  if ($null -eq $Action) { return $null }
  $value = Get-NestedValue -Obj $Action -Path 'prompt'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  $value = Get-NestedValue -Obj $Action -Path 'sample_prompt'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  $value = Get-NestedValue -Obj $Action -Path 'question'
  if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
  return $null
}

function Get-ActionPreconditions {
  param([object]$Action)
  if ($null -eq $Action) { return @() }
  return @(Get-StringArray (Get-NestedValue -Obj $Action -Path 'preconditions') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-ActionAssertions {
  param([object]$Action)
  if ($null -eq $Action) { return @() }
  return @(Get-StringArray (Get-NestedValue -Obj $Action -Path 'assertions') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-ActionNegativeAssertions {
  param([object]$Action)
  if ($null -eq $Action) { return @() }
  return @(Get-StringArray (Get-NestedValue -Obj $Action -Path 'negative_assertions') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-ActionVariantOverrides {
  param([object]$Action)
  $variants = Get-NestedValue -Obj $Action -Path 'variants'
  if ($null -eq $variants) { return $null }
  return $variants
}

function Get-ActionVariantNames {
  param([object]$Profile)
  $variantNames = @(Get-StringArray (Get-NestedValue -Obj $Profile -Path 'action_schema.variant_names') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($variantNames.Count -gt 0) {
    return @($variantNames)
  }
  return @('base', 'missing_preconditions', 'invalid_input', 'followup', 'blocked', 'confirmed')
}

function Get-ActionRequestHints {
  param([object]$Action)
  if ($null -eq $Action) { return @() }
  return @(Get-StringArray (Get-NestedValue -Obj $Action -Path 'input_hints') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-ActionAssertionSpec {
  param([object]$Action)
  if ($null -eq $Action) { return $null }
  $spec = Get-NestedValue -Obj $Action -Path 'assertion_spec'
  if ($null -ne $spec) { return $spec }
  $assertions = Get-NestedValue -Obj $Action -Path 'assertions'
  if ($assertions -is [System.Array] -or $assertions -is [string]) { return $null }
  if ($null -ne $assertions) { return $assertions }
  return $null
}

function Get-ActionTestIntent {
  param([object]$Action)
  if ($null -eq $Action) { return [ordered]@{} }
  return [ordered]@{
    prompt = Get-ActionPrompt -Action $Action
    preconditions = @(Get-ActionPreconditions -Action $Action)
    assertions = @(Get-ActionAssertions -Action $Action)
    negative_assertions = @(Get-ActionNegativeAssertions -Action $Action)
    input_hints = @(Get-ActionRequestHints -Action $Action)
    assertion_spec = Get-ActionAssertionSpec -Action $Action
    variants = Get-ActionVariantOverrides -Action $Action
  }
}

function Get-ActionCoverageSummary {
  param(
    [object]$Profile,
    [object]$Cases
  )

  $actions = Get-DeclaredOrSyntheticActions -Profile $Profile
  $caseActionMap = @{}
  foreach ($case in $cases) {
    $caseId = [string](Get-NestedValue -Obj $case -Path 'case_id')
    $actionId = [string](Get-NestedValue -Obj $case -Path 'action')
    if ([string]::IsNullOrWhiteSpace($actionId)) {
      continue
    }
    if (-not $caseActionMap.ContainsKey($actionId)) {
      $caseActionMap[$actionId] = New-Object System.Collections.Generic.List[string]
    }
    if (-not [string]::IsNullOrWhiteSpace($caseId) -and -not $caseActionMap[$actionId].Contains($caseId)) {
      [void]$caseActionMap[$actionId].Add($caseId)
    }
  }

  $actionDetails = foreach ($action in $actions) {
    $actionId = Get-ActionId -Action $action
    if ([string]::IsNullOrWhiteSpace($actionId)) {
      continue
    }
    $required = Get-ActionRequired -Action $action
    $caseIds = if ($caseActionMap.ContainsKey($actionId)) { @($caseActionMap[$actionId]) } else { @() }
    [ordered]@{
      action_id = $actionId
      label = Get-ActionLabel -Action $action
      required = $required
      risk = Get-ActionRisk -Action $action
      covered = ($caseIds.Count -gt 0)
      case_ids = $caseIds
      coverage_tags = @(Get-ActionCoverageTags -Action $action)
    }
  }

  $requiredActions = @($actionDetails | Where-Object { $_.required } | ForEach-Object { $_.action_id })
  $coveredActions = @($actionDetails | Where-Object { $_.covered } | ForEach-Object { $_.action_id })
  $missingRequiredActions = @($actionDetails | Where-Object { $_.required -and -not $_.covered } | ForEach-Object { $_.action_id })
  $requireAll = Test-Truthy (Get-NestedValue -Obj $Profile -Path 'coverage_policy.require_all_actions')
  if ($null -eq $Profile -or $null -eq $Profile.PSObject.Properties['coverage_policy']) {
    $requireAll = $true
  }
  $actionComplete = ($requireAll -and $missingRequiredActions.Count -eq 0) -or (-not $requireAll)

  [ordered]@{
    require_all_actions = $requireAll
    action_count = $actionDetails.Count
    required_actions = $requiredActions
    covered_actions = $coveredActions
    missing_required_actions = $missingRequiredActions
    action_complete = $actionComplete
    details = @($actionDetails)
  }
}

function Get-TextSlug {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $slug = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
  $slug = $slug.Trim('_')
  if ([string]::IsNullOrWhiteSpace($slug)) { return $null }
  return $slug
}

function New-SafeId {
  param(
    [string]$Prefix,
    [string]$Text,
    [int]$Index
  )
  $slug = Get-TextSlug -Text $Text
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = ('{0}_{1}' -f $Prefix, $Index)
  }
  return $slug
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-JsonArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 100
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Write-TextArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )
  Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

function Render-ReportMarkdown {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)]$Cases
  )

  $lines = @()
  $lines += ("# {0} v{1} 自动测评报告" -f $Result.request.skill_id, $Result.request.skill_version)
  $lines += ''
  $lines += '## 1. 元信息'
  $lines += ("- Gateway: {0}" -f $Result.diagnostics.gateway_url)
  $lines += ("- 输出目录: {0}" -f $Result.diagnostics.output_dir)
  $lines += ("- Adapter 类型: {0}" -f $Result.diagnostics.adapter_kind)
  $lines += ("- Adapter 名称: {0}" -f $Result.diagnostics.adapter_name)
  $lines += ("- Adapter 支持的技能形态: {0}" -f (($Result.diagnostics.adapter_supported_skill_shapes -join '、') -replace '^$', '无'))
  $lines += ("- Schema 版本: {0}" -f $Result.diagnostics.schema_version)
  $lines += ("- Profile 类型: {0}" -f $Result.diagnostics.profile_kind)
  $lines += ("- Action 必填字段: {0}" -f (($Result.diagnostics.action_schema_required_fields -join '、') -replace '^$', '无'))
  $lines += ("- Action 推荐字段: {0}" -f (($Result.diagnostics.action_schema_recommended_fields -join '、') -replace '^$', '无'))
  $lines += ("- Action 变体: {0}" -f (($Result.diagnostics.action_schema_variant_names -join '、') -replace '^$', '无'))
 $lines += ("- HTTP Status: {0}" -f $Result.diagnostics.http_status)
 $lines += ("- Case 总数: {0}" -f $Result.diagnostics.case_count)
 $lines += ("- 手工 Case: {0}" -f $Result.diagnostics.manual_case_count)
 $lines += ("- 自动生成 Case: {0}" -f $Result.diagnostics.generated_case_count)
 $lines += ("- 已执行 Case: {0}" -f $Result.diagnostics.executed_case_count)
 $lines += ("- 通过: {0}" -f $Result.diagnostics.pass_count)
 $lines += ("- 失败: {0}" -f $Result.diagnostics.fail_count)
 $lines += ("- 需复核: {0}" -f $Result.diagnostics.review_needed_count)
 $lines += ("- 跳过: {0}" -f $Result.diagnostics.skipped_count)
 $lines += ("- 总体判定: {0}" -f $Result.diagnostics.overall_judgement)
 $lines += ("- 覆盖完整性: {0}" -f $Result.diagnostics.coverage_complete)
 $lines += ("- Action 完整性: {0}" -f $Result.diagnostics.action_complete)
 $lines += ''
  $lines += '## 2. 覆盖摘要'
  $lines += '| 类型 | 是否完整 | 缺口 |'
  $lines += '| --- | --- | --- |'
  $lines += ("| 能力 | {0} | {1} |" -f $Result.coverage.coverage_complete, (($Result.coverage.missing_required_tags -join '、') -replace '^$', '无'))
  $lines += ("| Action | {0} | {1} |" -f $Result.action_coverage.action_complete, (($Result.action_coverage.missing_required_actions -join '、') -replace '^$', '无'))
  $lines += ''
  $lines += '## 3. Action 覆盖明细'
  $lines += '| Action ID | 名称 | 必测 | 是否覆盖 | 命中 Case | 风险 |'
  $lines += '| --- | --- | --- | --- | --- | --- |'
  foreach ($item in $Result.action_coverage.details) {
    $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $item.action_id, $item.label, $item.required, $item.covered, (($item.case_ids -join '、') -replace '^$', '无'), $item.risk)
  }
  $lines += ''
  $lines += '## 4. 能力覆盖明细'
  $lines += '| 能力标签 | 是否覆盖 | 命中 Case |'
  $lines += '| --- | --- | --- |'
  foreach ($item in $Result.coverage.details) {
    $lines += ('| {0} | {1} | {2} |' -f $item.tag, $item.covered, (($item.case_ids -join '、') -replace '^$', '无'))
  }
  $lines += ''
  $lines += '## 5. Case 生成情况'
  $lines += '| 模式 | 数量 |'
  $lines += '| --- | ---: |'
 $lines += ("| 自动生成 | {0} |" -f $Result.case_plan.generated_case_count)
 $lines += ("| 手工补充 | {0} |" -f $Result.case_plan.manual_case_count)
 $lines += ("| 合计 | {0} |" -f $Result.case_plan.effective_case_count)
 $lines += ''
 $lines += '## 6. Case 执行明细'
 $lines += '| Case ID | Action | Variant | HTTP | 判定 | 耗时(ms) |'
 $lines += '| --- | --- | --- | ---: | --- | ---: |'
 foreach ($run in ($Result.case_runs | Where-Object { $null -ne $_ })) {
   $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $run.case_id, $run.action, $run.variant, $run.http_status, $run.judgement, $run.elapsed_ms)
 }
 $lines += ''
 if ($null -ne $Result.error_info) {
   $lines += '## 7. 错误信息'
   $lines += ("- 类型: {0}" -f $Result.error_info.type)
   $lines += ("- 可读摘要: {0}" -f $Result.error_info.readable.user_message)
   $lines += ("- 建议: {0}" -f $Result.error_info.readable.suggestion)
   $lines += ''
 }
 $lines += '## 8. 附录'
 $lines += ("- cases.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'cases.json'))
 $lines += ("- real-conversation-replay.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'real-conversation-replay.json'))
 $lines += ("- coverage.summary.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'coverage.summary.json'))
 $lines += ("- action.coverage.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'action.coverage.json'))
 $lines += ("- case.plan.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'case.plan.json'))
 $lines += ("- case.runs.json: {0}" -f (Join-Path $Result.diagnostics.output_dir 'case.runs.json'))
  return ($lines -join "`r`n")
}

function Save-Artifacts {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)]$Profile,
    [object]$Matrix,
    [Parameter(Mandatory = $true)]$Cases,
    [object[]]$CaseRuns = @()
  )

  Ensure-Directory -Path $OutputDir

  Write-JsonArtifact -Path (Join-Path $OutputDir 'cases.json') -Value $Cases
  Write-JsonArtifact -Path (Join-Path $OutputDir 'real-conversation-replay.json') -Value $Result
  Write-JsonArtifact -Path (Join-Path $OutputDir 'profile.resolved.json') -Value $Profile
  Write-JsonArtifact -Path (Join-Path $OutputDir 'action.catalog.json') -Value (Get-ActionCatalog -Profile $Profile)
  Write-JsonArtifact -Path (Join-Path $OutputDir 'matrix.resolved.json') -Value ([ordered]@{
    profile_file = $ProfileFile
    manual_matrix = $Matrix
    effective_cases = $Cases
    case_plan = $Result.case_plan
  })
  Write-JsonArtifact -Path (Join-Path $OutputDir 'request.log.json') -Value $Result.request
  Write-JsonArtifact -Path (Join-Path $OutputDir 'coverage.summary.json') -Value $Result.coverage
  Write-JsonArtifact -Path (Join-Path $OutputDir 'action.coverage.json') -Value $Result.action_coverage
  Write-JsonArtifact -Path (Join-Path $OutputDir 'case.plan.json') -Value $Result.case_plan
  if ($CaseRuns.Count -gt 0) {
    Write-JsonArtifact -Path (Join-Path $OutputDir 'case.runs.json') -Value $CaseRuns
  }
  Write-TextArtifact -Path (Join-Path $OutputDir 'report.md') -Value (Render-ReportMarkdown -Result $Result -Cases $Cases)
}

function Get-DeclaredOrSyntheticActions {
  param([object]$Profile)

  $actions = Get-ActionArray -Profile $Profile
  if ($actions.Count -gt 0) {
    return @($actions)
  }

  $capabilities = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'capabilities')
  $requiredTags = Get-StringArray (Get-NestedValue -Obj $Profile -Path 'coverage_policy.required_tags')
  $fallbackTags = @()
  if ($capabilities.Count -gt 0) { $fallbackTags += $capabilities }
  if ($requiredTags.Count -gt 0) { $fallbackTags += $requiredTags }
  if ($fallbackTags.Count -eq 0) {
    $fallbackTags = @('鉴权接入', '核心流程', '边界与错误')
  }

  $fallbackTags = @($fallbackTags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  $synthetic = @()
  $index = 0
  foreach ($tag in $fallbackTags) {
    $index++
    $synthetic += [ordered]@{
      action_id = (New-SafeId -Prefix 'capability' -Text $tag -Index $index)
      label = $tag
      required = $true
      risk = 'medium'
      coverage_tags = @($tag)
      prompt = ('请验证“' + $tag + '”能力是否可以正常工作。')
      preconditions = @()
      assertions = @('应返回与“' + $tag + '”能力一致的结果')
      negative_assertions = @()
      input_hints = @($tag)
      synthetic = $true
      source = 'profile.capabilities'
    }
  }

  return @($synthetic)
}

function Test-HighRiskAction {
  param([object]$Action)
  if ($null -eq $Action) { return $false }

  $risk = [string](Get-ActionRisk -Action $Action)
  if ($risk -in @('high', 'irreversible')) { return $true }

  $label = [string](Get-ActionLabel -Action $Action)
  if (-not [string]::IsNullOrWhiteSpace($label)) {
    if ($label -match '写|更新|删除|创建|发布|提交|审批|拒绝|执行|取消|回滚|write|update|delete|create|publish|submit|approve|reject|execute|cancel|rollback') {
      return $true
    }
  }

  foreach ($tag in (Get-ActionCoverageTags -Action $Action)) {
    if ($tag -eq '副作用确认' -or $tag -eq '写操作') {
      return $true
    }
  }

  return $false
}

function Get-GeneratedCaseLayer {
  param([object]$Action)

  $tags = Get-ActionCoverageTags -Action $Action
  $joined = ($tags -join ' ')
  if ($joined -match '副作用确认|写操作') { return 'E-副作用与确认' }
  if ($joined -match '边界与错误') { return 'D-边界与错误' }
  if ($joined -match '自然语言交互|多轮上下文') { return 'C-自然语言交互' }
  if ($joined -match '核心流程') { return 'B-核心能力' }
  if ($joined -match '鉴权接入') { return 'A-基础接入' }
  return 'Z-自动生成'
}

function Get-GeneratedCaseQuestion {
  param(
    [object]$Action,
    [string]$Variant = 'base'
  )

  $label = [string](Get-ActionLabel -Action $Action)
  if ([string]::IsNullOrWhiteSpace($label)) {
    $label = [string](Get-ActionId -Action $Action)
  }
  if ([string]::IsNullOrWhiteSpace($label)) {
    $label = '未命名动作'
  }

  $prompt = Get-ActionPrompt -Action $Action
  $preconditions = @(Get-ActionPreconditions -Action $Action)
  $variantOverrides = Get-ActionVariantOverrides -Action $Action

  if ($null -ne $variantOverrides) {
    $variantNode = Get-NestedValue -Obj $variantOverrides -Path $Variant
    if ($null -ne $variantNode) {
      $overridePrompt = Get-NestedValue -Obj $variantNode -Path 'prompt'
      if ([string]::IsNullOrWhiteSpace([string]$overridePrompt)) {
        $overridePrompt = Get-NestedValue -Obj $variantNode -Path 'question'
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$overridePrompt)) {
        return [string]$overridePrompt
      }
    }
  }

  if ($Variant -eq 'blocked') {
    return ('请尝试触发一次“{0}”，但不要确认写入或不可逆操作；系统应拦截或提示风险。' -f $label)
  }
  if ($Variant -eq 'confirmed') {
    return ('请在明确授权后执行“{0}”，并返回完整结果。' -f $label)
  }
  if ($Variant -eq 'followup') {
    return ('请在上文上下文的基础上继续完成“{0}”，保持多轮一致性。' -f $label)
  }
  if ($Variant -eq 'missing_preconditions') {
    return ('在缺少前置条件的情况下尝试“{0}”，验证系统是否给出清晰的补救提示。' -f $label)
  }
  if ($Variant -eq 'invalid_input') {
    return ('请为“{0}”构造一个明显不合法的输入，检查错误提示是否足够明确。' -f $label)
  }

  if (-not [string]::IsNullOrWhiteSpace($prompt)) {
    return $prompt
  }

  if ($preconditions.Count -gt 0) {
    return ('请基于前置条件 {0} 执行“{1}”。' -f ($preconditions -join '；'), $label)
  }

  return ('请验证“{0}”是否可以正常完成其核心动作。' -f $label)
}

function Get-GeneratedCaseExpected {
  param(
    [object]$Action,
    [string]$Variant = 'base'
  )

  if ($Variant -eq 'blocked') {
    return '应拦截风险操作，或明确给出拒绝/确认提示。'
  }
  if ($Variant -eq 'confirmed') {
    return '应在确认后继续执行，并返回可读结果。'
  }
  if ($Variant -eq 'followup') {
    return '应保持多轮上下文一致，并正确衔接追问。'
  }
  if ($Variant -eq 'missing_preconditions') {
    return '应提示缺失前置条件，并给出可执行的补救建议。'
  }
  if ($Variant -eq 'invalid_input') {
    return '应返回明确的参数校验失败或错误说明。'
  }

  $risk = [string](Get-ActionRisk -Action $Action)
  if ($risk -in @('high', 'irreversible')) {
    return '应对高风险动作给出明确结果，并在必要时触发确认。'
  }
  $assertions = @(Get-ActionAssertions -Action $Action)
  if ($assertions.Count -gt 0) {
    return ($assertions -join '；')
  }
  return '应返回与动作一致的结果，或给出可读失败原因。'
}

function Get-GeneratedCaseExpectedStatuses {
  param(
    [object]$Action,
    [string]$Variant = 'base'
  )

  $actionId = [string](Get-ActionId -Action $Action)
  $risk = [string](Get-ActionRisk -Action $Action)

  if ($Variant -eq 'blocked') {
    return @(400, 401, 403, 409, 422)
  }
  if ($Variant -eq 'confirmed') {
    return @(200, 201, 202)
  }
  if ($Variant -eq 'followup') {
    return @(200, 201, 202)
  }
  if ($Variant -eq 'missing_preconditions' -or $Variant -eq 'invalid_input') {
    return @(400, 409, 422)
  }

  if ($actionId -match 'auth_missing|auth_invalid') {
    return @(401, 403)
  }
  if ($actionId -match 'version_missing|param_missing|param_invalid') {
    return @(400, 422)
  }
  if ($risk -in @('high', 'irreversible')) {
    return @(200, 201, 202, 400, 403, 409, 422)
  }
  return @(200, 201, 202)
}

function Get-GeneratedCaseVariants {
  param(
    [object]$Profile,
    [object]$Action
  )

  $variantNames = @(Get-ActionVariantNames -Profile $Profile)
  $variants = @()
  $preconditions = @(Get-ActionPreconditions -Action $Action)
  $negativeAssertions = @(Get-ActionNegativeAssertions -Action $Action)
  $prompt = Get-ActionPrompt -Action $Action

  if ($variantNames -contains 'base') {
    $variants += 'base'
  }
  if (($preconditions.Count -gt 0) -and ($variantNames -contains 'missing_preconditions')) {
    $variants += 'missing_preconditions'
  }
  if ((($negativeAssertions.Count -gt 0) -or ((Get-ActionCoverageTags -Action $Action) | Where-Object { $_ -match '边界|错误|参数|校验' })) -and ($variantNames -contains 'invalid_input')) {
    $variants += 'invalid_input'
  }
  if ((-not [string]::IsNullOrWhiteSpace([string]$prompt)) -and ($variantNames -contains 'followup')) {
    $variants += 'followup'
  }
  if ((Test-HighRiskAction -Action $Action) -and ($variantNames -contains 'blocked')) {
    $variants += 'blocked'
  }
  if ((Test-HighRiskAction -Action $Action) -and ($variantNames -contains 'confirmed')) {
    $variants += 'confirmed'
  }
  foreach ($tag in (Get-ActionCoverageTags -Action $Action)) {
    if (($tag -eq '多轮上下文') -and ($variantNames -contains 'followup')) {
      $variants += 'followup'
    }
  }
  return @($variants | Select-Object -Unique)
}

function Get-GeneratedCasesFromActions {
  param([object]$Profile)

  $actions = Get-DeclaredOrSyntheticActions -Profile $Profile
  $cases = @()
  foreach ($action in $actions) {
    $actionId = [string](Get-ActionId -Action $action)
    if ([string]::IsNullOrWhiteSpace($actionId)) {
      continue
    }
      foreach ($variant in (Get-GeneratedCaseVariants -Profile $Profile -Action $action)) {
      $caseId = if ($variant -eq 'base') {
        ('AUTO-{0}' -f $actionId)
      } else {
        ('AUTO-{0}-{1}' -f $actionId, $variant.ToUpperInvariant())
      }
      $coverageTags = @(Get-ActionCoverageTags -Action $action)
      $layer = Get-GeneratedCaseLayer -Action $action
      $expectedStatuses = @(Get-GeneratedCaseExpectedStatuses -Action $action -Variant $variant)
      $responseContains = @(Get-StringArray (Get-NestedValue -Obj $action -Path 'response_contains'))
      $responseNotContains = @(Get-StringArray (Get-NestedValue -Obj $action -Path 'response_not_contains'))
      $expectedGatewayCodes = @(Get-StringArray (Get-NestedValue -Obj $action -Path 'expected_gateway_code_in'))
      $cases += [ordered]@{
        case_id = $caseId
        layer = $layer
        action = $actionId
        coverage_tags = $coverageTags
        question = Get-GeneratedCaseQuestion -Action $action -Variant $variant
        expected = Get-GeneratedCaseExpected -Action $action -Variant $variant
        prompt = Get-ActionPrompt -Action $action
        preconditions = @(Get-ActionPreconditions -Action $action)
        assertions = @(Get-ActionAssertions -Action $action)
        negative_assertions = @(Get-ActionNegativeAssertions -Action $action)
        input_hints = @(Get-ActionRequestHints -Action $action)
        expected_http_status_in = @($expectedStatuses)
        expected_gateway_code_in = @($expectedGatewayCodes)
        response_contains = @($responseContains)
        response_not_contains = @($responseNotContains)
        assertion_spec = [ordered]@{
          http_status_in = @($expectedStatuses)
          gateway_code_in = @($expectedGatewayCodes)
          response_contains = @($responseContains)
          response_not_contains = @($responseNotContains)
        }
        judgement = 'Pending'
        generated = $true
        variant = $variant
        source = 'auto.profile'
      }
    }
  }

  return @($cases)
}

function Get-EffectiveCaseArray {
  param(
    [object]$Profile,
    [object]$Matrix
  )

  $manualCases = Get-CaseArray -Matrix $Matrix
  $generatedCases = Get-GeneratedCasesFromActions -Profile $Profile

  if ($manualCases.Count -eq 0) {
    return @($generatedCases)
  }

  $byAction = @{}
  $byCaseId = @{}
  $effective = @()

  foreach ($manual in $manualCases) {
    $caseId = [string](Get-NestedValue -Obj $manual -Path 'case_id')
    $actionId = [string](Get-NestedValue -Obj $manual -Path 'action')
    if (-not [string]::IsNullOrWhiteSpace($actionId)) {
      $byAction[$actionId] = $manual
    }
    if (-not [string]::IsNullOrWhiteSpace($caseId)) {
      $byCaseId[$caseId] = $manual
    }
    $effective += $manual
  }

  foreach ($generated in $generatedCases) {
    $caseId = [string](Get-NestedValue -Obj $generated -Path 'case_id')
    $actionId = [string](Get-NestedValue -Obj $generated -Path 'action')
    $variant = [string](Get-NestedValue -Obj $generated -Path 'variant')
    if (-not [string]::IsNullOrWhiteSpace($actionId) -and $byAction.ContainsKey($actionId) -and $variant -eq 'base') {
      continue
    }
    if (-not [string]::IsNullOrWhiteSpace($caseId) -and $byCaseId.ContainsKey($caseId)) {
      continue
    }
    $effective += $generated
  }

  return @($effective)
}

function Get-ActionCatalog {
  param([object]$Profile)
  return @(Get-DeclaredOrSyntheticActions -Profile $Profile)
}

function Get-RequestMapping {
  param([object]$Profile)

  $adapter = Get-AdapterProfile -Profile $Profile
  $mapping = Get-NestedValue -Obj $adapter -Path 'request_mapping'
  if ($null -eq $mapping) {
    $mapping = Get-NestedValue -Obj $Profile -Path 'request_mapping'
  }
  $promptPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'prompt_paths')
  if ($promptPaths.Count -eq 0) {
    $promptPaths = @('prompt', 'question', 'input', 'query', 'content', 'text')
  }
  $actionPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'action_paths')
  if ($actionPaths.Count -eq 0) {
    $actionPaths = @('action', 'operation', 'intent', 'mode', 'type', 'risk')
  }
  $contextPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'context_paths')
  if ($contextPaths.Count -eq 0) {
    $contextPaths = @('context', 'history', 'conversation')
  }
  $caseIdPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'case_id_paths')
  if ($caseIdPaths.Count -eq 0) {
    $caseIdPaths = @('meta.case_id', 'metadata.case_id')
  }
  $variantPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'variant_paths')
  if ($variantPaths.Count -eq 0) {
    $variantPaths = @('meta.variant', 'metadata.variant')
  }
  $coveragePaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'coverage_paths')
  if ($coveragePaths.Count -eq 0) {
    $coveragePaths = @('meta.coverage_tags', 'metadata.coverage_tags')
  }
  $metadataPath = [string](Get-NestedValue -Obj $mapping -Path 'metadata_path')
  if ([string]::IsNullOrWhiteSpace($metadataPath)) {
    $metadataPath = 'meta'
  }

  return [ordered]@{
    prompt_paths = @($promptPaths)
    action_paths = @($actionPaths)
    context_paths = @($contextPaths)
    case_id_paths = @($caseIdPaths)
    variant_paths = @($variantPaths)
    coverage_paths = @($coveragePaths)
    metadata_path = $metadataPath
  }
}

function Get-ResponseMapping {
  param([object]$Profile)

  $adapter = Get-AdapterProfile -Profile $Profile
  $mapping = Get-NestedValue -Obj $adapter -Path 'response_mapping'
  if ($null -eq $mapping) {
    $mapping = Get-NestedValue -Obj $Profile -Path 'response_mapping'
  }

  $gatewayCodePaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'gateway_code_paths')
  if ($gatewayCodePaths.Count -eq 0) {
    $gatewayCodePaths = @('code', 'data.code', 'result.code', 'status.code')
  }
  $messagePaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'message_paths')
  if ($messagePaths.Count -eq 0) {
    $messagePaths = @('message', 'data.message', 'result.message', 'status.message')
  }
  $resultPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'result_paths')
  if ($resultPaths.Count -eq 0) {
    $resultPaths = @('data.result', 'data.output', 'data.answer', 'data.content', 'result', 'output', 'answer', 'content', 'payload')
  }
  $versionPaths = Get-StringArray (Get-NestedValue -Obj $mapping -Path 'version_paths')
  if ($versionPaths.Count -eq 0) {
    $versionPaths = @('data.version_info', 'version_info', 'meta.version')
  }

  return [ordered]@{
    gateway_code_paths = @($gatewayCodePaths)
    message_paths = @($messagePaths)
    result_paths = @($resultPaths)
    version_paths = @($versionPaths)
  }
}

function Set-RequestValue {
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string[]]$Paths,
    [Parameter(Mandatory = $true)]$Value
  )

  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if ($path -eq 'messages') {
      Set-NestedValue -Obj $Obj -Path $path -Value @([ordered]@{ role = 'user'; content = [string]$Value })
      return
    }
    Set-NestedValue -Obj $Obj -Path $path -Value $Value
    return
  }
}

function Build-CasePayload {
  param(
    [Parameter(Mandatory = $true)]$BasePayload,
    [Parameter(Mandatory = $true)]$Case,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string]$SkillId,
    [Parameter(Mandatory = $true)][string]$SkillVersion,
    [Parameter(Mandatory = $false)][string]$SkillIdField = 'skill_id',
    [Parameter(Mandatory = $false)][string]$SkillVersionField = '_skill_version',
    [switch]$DisableFieldInjection
  )

  $payload = Copy-DeepObject -Obj $BasePayload
  if ($null -eq $payload) {
    $payload = [ordered]@{}
  }

  if (-not $DisableFieldInjection) {
    Set-OrAddProperty -Obj $payload -Name $SkillIdField -Value $SkillId
    Set-OrAddProperty -Obj $payload -Name $SkillVersionField -Value $SkillVersion
  }

  $mapping = Get-RequestMapping -Profile $Profile
  $caseId = [string](Get-NestedValue -Obj $Case -Path 'case_id')
  $actionId = [string](Get-NestedValue -Obj $Case -Path 'action')
  $variant = [string](Get-NestedValue -Obj $Case -Path 'variant')
  $prompt = [string](Get-NestedValue -Obj $Case -Path 'question')
  $coverageTags = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'coverage_tags'))
  $preconditions = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'preconditions'))

  Set-RequestValue -Obj $payload -Paths $mapping.prompt_paths -Value $prompt
  Set-RequestValue -Obj $payload -Paths $mapping.action_paths -Value $actionId
  if ($variant -ne 'missing_preconditions' -and $preconditions.Count -gt 0) {
    Set-RequestValue -Obj $payload -Paths $mapping.context_paths -Value ($preconditions -join '；')
  }

  $confirmFields = @(Get-StringArray (Get-NestedValue -Obj $Profile -Path 'risk.confirm_flag_fields'))
  foreach ($field in $confirmFields) {
    if ([string]::IsNullOrWhiteSpace($field)) { continue }
    if ($variant -eq 'confirmed') {
      Set-NestedValue -Obj $payload -Path $field -Value $true
    } elseif ($variant -eq 'blocked') {
      Set-NestedValue -Obj $payload -Path $field -Value $false
    }
  }

  $intentFields = @(Get-StringArray (Get-NestedValue -Obj $Profile -Path 'risk.intent_fields'))
  foreach ($field in $intentFields) {
    if ([string]::IsNullOrWhiteSpace($field)) { continue }
    Set-NestedValue -Obj $payload -Path $field -Value $actionId
  }

  $meta = [ordered]@{
    case_id = $caseId
    action = $actionId
    variant = $variant
    adapter_kind = Get-AdapterKind -Profile $Profile
    adapter_name = Get-AdapterName -Profile $Profile
    coverage_tags = $coverageTags
    generated = Test-Truthy (Get-NestedValue -Obj $Case -Path 'generated')
    expected_http_status_in = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'expected_http_status_in'))
    assertions = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'assertions'))
    negative_assertions = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'negative_assertions'))
  }

  Set-NestedValue -Obj $payload -Path $mapping.metadata_path -Value $meta
  foreach ($path in $mapping.case_id_paths) {
    Set-NestedValue -Obj $payload -Path $path -Value $caseId
  }
  foreach ($path in $mapping.variant_paths) {
    Set-NestedValue -Obj $payload -Path $path -Value $variant
  }
  foreach ($path in $mapping.coverage_paths) {
    Set-NestedValue -Obj $payload -Path $path -Value $coverageTags
  }

  return $payload
}

function Evaluate-CaseResult {
  param(
    [Parameter(Mandatory = $true)]$Case,
    [int]$HttpStatus,
    [string]$RawText,
    [object]$Parsed,
    [string]$GatewayCode,
    [string]$Message,
    [object]$ResultPayload,
    [object]$VersionMeta
  )

  $expectedStatuses = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'expected_http_status_in'))
  $expectedGatewayCodes = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'expected_gateway_code_in'))
  $responseContains = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'response_contains'))
  $responseNotContains = @(Get-StringArray (Get-NestedValue -Obj $Case -Path 'response_not_contains'))

  $sourceText = @()
  if (-not [string]::IsNullOrWhiteSpace($Message)) { $sourceText += $Message }
  if (-not [string]::IsNullOrWhiteSpace($RawText)) { $sourceText += $RawText }
  if ($null -ne $Parsed) { $sourceText += ((($Parsed | ConvertTo-Json -Depth 100) -replace '\\s+', ' ')) }
  if ($null -ne $ResultPayload) {
    if ($ResultPayload -is [string]) {
      $sourceText += [string]$ResultPayload
    } else {
      $sourceText += ($ResultPayload | ConvertTo-Json -Depth 100)
    }
  }
  if ($null -ne $VersionMeta) {
    if ($VersionMeta -is [string]) {
      $sourceText += [string]$VersionMeta
    } else {
      $sourceText += ($VersionMeta | ConvertTo-Json -Depth 100)
    }
  }
  $sourceText = ($sourceText -join "`n")

  $checks = @()
  $failures = @()

  if ($expectedStatuses.Count -gt 0) {
    $checks += [ordered]@{
      check = 'http_status_in'
      expected = @($expectedStatuses)
      observed = $HttpStatus
      passed = ($expectedStatuses -contains $HttpStatus)
    }
    if ($expectedStatuses -notcontains $HttpStatus) {
      $failures += ('HTTP 状态 {0} 不在期望集合 {1} 中' -f $HttpStatus, ($expectedStatuses -join '、'))
    }
  }

  if ($expectedGatewayCodes.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($GatewayCode)) {
    $checks += [ordered]@{
      check = 'gateway_code_in'
      expected = @($expectedGatewayCodes)
      observed = $GatewayCode
      passed = ($expectedGatewayCodes -contains $GatewayCode)
    }
    if ($expectedGatewayCodes -notcontains $GatewayCode) {
      $failures += ('网关码 {0} 不在期望集合 {1} 中' -f $GatewayCode, ($expectedGatewayCodes -join '、'))
    }
  }

  foreach ($needle in $responseContains) {
    $passed = ($sourceText -match [regex]::Escape($needle))
    $checks += [ordered]@{
      check = 'response_contains'
      expected = $needle
      observed = $passed
      passed = $passed
    }
    if (-not $passed) {
      $failures += ('响应中缺少期望内容: {0}' -f $needle)
    }
  }

  foreach ($needle in $responseNotContains) {
    $passed = (-not ($sourceText -match [regex]::Escape($needle)))
    $checks += [ordered]@{
      check = 'response_not_contains'
      expected = $needle
      observed = $passed
      passed = $passed
    }
    if (-not $passed) {
      $failures += ('响应中出现了不应出现的内容: {0}' -f $needle)
    }
  }

  if ($checks.Count -eq 0) {
    return [ordered]@{
      judgement = 'review_needed'
      passed = $null
      checks = @()
      failures = @('未提供可机器校验的断言')
    }
  }

  $passed = ($failures.Count -eq 0)
  return [ordered]@{
    judgement = if ($passed) { 'pass' } else { 'fail' }
    passed = $passed
    checks = @($checks)
    failures = @($failures)
  }
}

function Invoke-CaseRun {
  param(
    [Parameter(Mandatory = $true)]$Case,
    [Parameter(Mandatory = $true)]$BasePayload,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string]$GatewayUrl,
    [Parameter(Mandatory = $true)]$Headers,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SkillId,
    [Parameter(Mandatory = $true)][string]$SkillVersion,
    [Parameter(Mandatory = $true)][string]$SkillIdField,
    [Parameter(Mandatory = $true)][string]$SkillVersionField,
    [Parameter(Mandatory = $true)][string]$SensitiveMode,
    [switch]$DisableFieldInjection,
    [switch]$Pretty
  )

  $caseId = [string](Get-NestedValue -Obj $Case -Path 'case_id')
  $actionId = [string](Get-NestedValue -Obj $Case -Path 'action')
  $variant = [string](Get-NestedValue -Obj $Case -Path 'variant')
  $payload = Build-CasePayload -BasePayload $BasePayload -Case $Case -Profile $Profile -SkillId $SkillId -SkillVersion $SkillVersion -SkillIdField $SkillIdField -SkillVersionField $SkillVersionField -DisableFieldInjection:$DisableFieldInjection

  $isSensitive = Is-SensitivePayload -PayloadObj $payload -Profile $Profile
  if ($isSensitive) {
    if ($SensitiveMode -eq 'always_block') {
      return [ordered]@{
        case_id = $caseId
        action = $actionId
        variant = $variant
        generated = Test-Truthy (Get-NestedValue -Obj $Case -Path 'generated')
        skipped = $true
        judgement = 'skipped'
        passed = $null
        reason = '敏感用例在当前模式下被跳过'
        elapsed_ms = 0
        http_status = $null
        gateway_code = $null
        message = $null
        payload = $payload
        response = $null
        evaluation = $null
        error_info = $null
      }
    }
    if ($SensitiveMode -eq 'ask') {
      Write-Host ('检测到敏感用例: {0} / {1}，当前模式需要人工确认。' -f $caseId, $actionId)
      Write-Host ('Question: {0}' -f (Get-NestedValue -Obj $Case -Path 'question'))
      $ans = Read-Host '请输入 1 继续，或 2 跳过'
      if ($ans -ne '1') {
        return [ordered]@{
          case_id = $caseId
          action = $actionId
          variant = $variant
          generated = Test-Truthy (Get-NestedValue -Obj $Case -Path 'generated')
          skipped = $true
          judgement = 'skipped'
          passed = $null
          reason = '用户确认跳过'
          elapsed_ms = 0
          http_status = $null
          gateway_code = $null
          message = $null
          payload = $payload
          response = $null
          evaluation = $null
          error_info = $null
        }
      }
    }
  }

  $body = $payload | ConvertTo-Json -Depth 100
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $status = $null
  $rawText = $null
  $parsed = $null
  $errorInfo = $null

  try {
    $resp = Invoke-WebRequest -Uri $GatewayUrl -Method Post -Headers $Headers -Body $body -TimeoutSec $TimeoutSec
    $status = [int]$resp.StatusCode
    $rawText = $resp.Content
    $parsed = Parse-ResponseText -Text $rawText
  } catch {
    if ($_.Exception.Response) {
      try {
        $status = [int]$_.Exception.Response.StatusCode.value__
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $rawText = $reader.ReadToEnd()
        $reader.Close()
        $parsed = Parse-ResponseText -Text $rawText
      } catch {
        $errorInfo = $_.Exception.Message
      }
    } else {
      $errorInfo = $_.Exception.Message
    }
  }

  $responseMapping = Get-ResponseMapping -Profile $Profile
  $gatewayCodePaths = @($responseMapping.gateway_code_paths)
  $messagePaths = @($responseMapping.message_paths)
  $resultPaths = @($responseMapping.result_paths)
  $versionPaths = @($responseMapping.version_paths)

  $gatewayCode = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $gatewayCodePaths } else { $null }
  $message = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $messagePaths } else { $null }
  $resultPayload = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $resultPaths } else { $null }
  $versionMeta = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $versionPaths } else { $null }
  if ($null -eq $resultPayload -and $parsed) {
    $resultPayload = $parsed
  }

  $statusValue = 0
  if ($null -ne $status) {
    $statusValue = [int]$status
  }
  $evaluation = Evaluate-CaseResult -Case $Case -HttpStatus $statusValue -RawText $rawText -Parsed $parsed -GatewayCode ([string]$gatewayCode) -Message ([string]$message) -ResultPayload $resultPayload -VersionMeta $versionMeta
  $sw.Stop()

  return [ordered]@{
    case_id = $caseId
    action = $actionId
    variant = $variant
    generated = Test-Truthy (Get-NestedValue -Obj $Case -Path 'generated')
    skipped = $false
    judgement = $evaluation.judgement
    passed = $evaluation.passed
    elapsed_ms = [int]$sw.ElapsedMilliseconds
    http_status = $status
    gateway_code = $gatewayCode
    message = $message
    payload = $payload
    request = [ordered]@{
      payload_file = $PayloadFile
      skill_id = $SkillId
      skill_version = $SkillVersion
      field_injection = [ordered]@{
        enabled = (-not $DisableFieldInjection)
        skill_id_field = $SkillIdField
        skill_version_field = $SkillVersionField
      }
      sensitive_mode = $SensitiveMode
    }
    response = [ordered]@{
      parsed_json = if ($Pretty) { $parsed } else { $null }
      raw_text = if ($null -eq $parsed) { $rawText } else { $null }
      result_payload = $resultPayload
      version_meta = $versionMeta
    }
    evaluation = $evaluation
    error_info = $errorInfo
  }
}

function Get-CaseRunSummary {
  param([object[]]$CaseRuns)

  $passCount = @($CaseRuns | Where-Object { $_.judgement -eq 'pass' }).Count
  $failCount = @($CaseRuns | Where-Object { $_.judgement -eq 'fail' }).Count
  $reviewCount = @($CaseRuns | Where-Object { $_.judgement -eq 'review_needed' }).Count
  $skippedCount = @($CaseRuns | Where-Object { $_.skipped }).Count

  $overall = if ($failCount -gt 0) {
    'Fail'
  } elseif ($reviewCount -gt 0) {
    'Partial'
  } elseif ($passCount -gt 0) {
    'Pass'
  } else {
    'Partial'
  }

  return [ordered]@{
    overall_judgement = $overall
    pass_count = $passCount
    fail_count = $failCount
    review_needed_count = $reviewCount
    skipped_count = $skippedCount
    executed_count = @($CaseRuns | Where-Object { -not $_.skipped }).Count
    total_count = @($CaseRuns).Count
  }
}

# 新批量执行路径：按 case 自动执行、评估并输出汇总结果。
try {
  $resolvedTarget = $null
  $resolvedTargetInfo = $null
  if (-not [string]::IsNullOrWhiteSpace($TargetQuery) -or $DiscoverTargetSkill) {
    $resolvedTarget = Resolve-SkillTarget -TargetQuery $TargetQuery -WorkspaceRoot $TargetRoot -CurrentSkillRoot $PSScriptRoot
    if ($null -ne $resolvedTarget) {
      $resolvedTargetInfo = [ordered]@{
        discovered = $true
        query = $TargetQuery
        workspace_root = $TargetRoot
        skill_directory = [string]$resolvedTarget.skill_directory
        skill_markdown = [string]$resolvedTarget.skill_markdown
        profile_file = [string]$resolvedTarget.profile_file
        payload_file = [string]$resolvedTarget.payload_file
        case_matrix_file = [string]$resolvedTarget.case_matrix_file
        skill_id = [string]$resolvedTarget.skill_id
        skill_version = [string]$resolvedTarget.skill_version
        skill_name = [string]$resolvedTarget.skill_name
        adapter_kind = [string]$resolvedTarget.adapter_kind
        score = [int]$resolvedTarget.score
      }

      if (-not $PSBoundParameters.ContainsKey('ProfileFile') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.profile_file)) {
        $ProfileFile = [string]$resolvedTarget.profile_file
      }
      if (-not $PSBoundParameters.ContainsKey('PayloadFile') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.payload_file)) {
        $PayloadFile = [string]$resolvedTarget.payload_file
      }
      if (-not $PSBoundParameters.ContainsKey('CaseMatrixFile') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.case_matrix_file)) {
        $CaseMatrixFile = [string]$resolvedTarget.case_matrix_file
      }
      if (-not $PSBoundParameters.ContainsKey('OutputDir') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.skill_directory)) {
        $skillName = [System.IO.Path]::GetFileName([string]$resolvedTarget.skill_directory)
        $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("skillscout-artifacts-{0}" -f $skillName)
      }
      if (-not $PSBoundParameters.ContainsKey('SkillId') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.skill_id)) {
        $SkillId = [string]$resolvedTarget.skill_id
      }
      if (-not $PSBoundParameters.ContainsKey('SkillVersion') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedTarget.skill_version)) {
        $SkillVersion = [string]$resolvedTarget.skill_version
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($TargetQuery) -or $DiscoverTargetSkill) {
      $targetQueryLabel = $TargetQuery
      if ([string]::IsNullOrWhiteSpace($targetQueryLabel)) {
        $targetQueryLabel = '<空>'
      }
      Write-Host ("未能根据目标描述解析到 skill: {0}" -f $targetQueryLabel)
      exit 1
    }
  }

  $profile = $null
  if (-not [string]::IsNullOrWhiteSpace($ProfileFile) -and (Test-Path -LiteralPath $ProfileFile)) {
    $profile = Read-JsonFile -Path $ProfileFile
  }

  if ([string]::IsNullOrWhiteSpace($SkillId) -and $null -ne $profile) {
    $SkillId = [string](Get-NestedValue -Obj $profile -Path 'skill_id')
  }
  if ([string]::IsNullOrWhiteSpace($SkillVersion)) {
    $profileSkillVersion = if ($null -ne $profile) { [string](Get-NestedValue -Obj $profile -Path 'skill_version') } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($profileSkillVersion)) {
      $SkillVersion = $profileSkillVersion
    }
  }
  if ([string]::IsNullOrWhiteSpace($SkillId)) {
    Write-Host '缺少 SkillId。请显式传入，或通过 TargetQuery / profile 自动解析目标 skill。'
    exit 1
  }

  $caseMatrix = $null
  if (-not [string]::IsNullOrWhiteSpace($CaseMatrixFile) -and (Test-Path -LiteralPath $CaseMatrixFile)) {
    $caseMatrix = Read-JsonFile -Path $CaseMatrixFile
  }

  $resolvedGatewayUrl = Resolve-Value -Primary $GatewayUrl -Secondary (Get-NestedValue -Obj $profile -Path 'transport.gateway_url') -Fallback ''
  if ([string]::IsNullOrWhiteSpace([string]$resolvedGatewayUrl)) {
    Write-Host '缺少 GatewayUrl。请通过参数传入，或在 profile 的 transport.gateway_url 中配置。'
    exit 1
  }

  $resolvedApiKeyEnv = Resolve-Value -Primary $ApiKeyEnv -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_env') -Fallback 'API_KEY'
  $resolvedApiKeyHeader = Resolve-Value -Primary $ApiKeyHeader -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_header') -Fallback 'Authorization'
  $resolvedApiKeyPrefix = Resolve-Value -Primary $ApiKeyPrefix -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_prefix') -Fallback 'Bearer '
  $resolvedSkillIdField = Resolve-Value -Primary $SkillIdField -Secondary (Get-NestedValue -Obj $profile -Path 'fields.skill_id') -Fallback 'skill_id'
  $resolvedSkillVersionField = Resolve-Value -Primary $SkillVersionField -Secondary (Get-NestedValue -Obj $profile -Path 'fields.skill_version') -Fallback '_skill_version'
  $resolvedSensitiveMode = Resolve-Value -Primary $SensitiveMode -Secondary (Get-NestedValue -Obj $profile -Path 'risk.default_mode') -Fallback 'ask'
  $resolvedSensitiveMode = [string]$resolvedSensitiveMode
  if ([string]::IsNullOrWhiteSpace($resolvedSensitiveMode)) {
    $resolvedSensitiveMode = 'ask'
  }
  if ($resolvedSensitiveMode -notin @('ask', 'always_allow', 'always_block')) {
    Write-Host ("无效的 SensitiveMode: {0}" -f $resolvedSensitiveMode)
    exit 1
  }

  $timeoutSec = 60
  $profileTimeout = Get-NestedValue -Obj $profile -Path 'transport.timeout_sec'
  if ($null -ne $profileTimeout) {
    try { $timeoutSec = [int]$profileTimeout } catch {}
  }

  $apiKey = [Environment]::GetEnvironmentVariable($resolvedApiKeyEnv)
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host ("当前未检测到本地环境变量 {0}，请先配置后再继续使用。" -f $resolvedApiKeyEnv)
    exit 1
  }

  if (-not (Test-Path -LiteralPath $PayloadFile)) {
    Write-Host ("未找到请求文件: {0}" -f $PayloadFile)
    exit 1
  }

  try {
    $payloadObj = Read-JsonFile -Path $PayloadFile
  } catch {
    Write-Host '请求体 JSON 解析失败，请检查 payload 文件格式。'
    exit 1
  }

  if (-not $DisableFieldInjection) {
    $profileFieldInjection = Get-NestedValue -Obj $profile -Path 'field_injection.enabled'
    if ($null -ne $profileFieldInjection -and -not (Test-Truthy $profileFieldInjection)) {
      $DisableFieldInjection = $true
    }
  }

  $headers = @{
    'Content-Type' = 'application/json'
  }
  $headers[$resolvedApiKeyHeader] = ("{0}{1}" -f $resolvedApiKeyPrefix, $apiKey)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $effectiveCases = Get-EffectiveCaseArray -Profile $profile -Matrix $caseMatrix
  $manualCaseCount = (Get-CaseArray -Matrix $caseMatrix).Count
  $generatedCaseCount = (@(Get-GeneratedCasesFromActions -Profile $profile)).Count
  $caseCount = $effectiveCases.Count
  $coverageSummary = Get-CoverageSummary -Profile $profile -Cases $effectiveCases
  $actionSummary = Get-ActionCoverageSummary -Profile $profile -Cases $effectiveCases

  $caseRuns = @()
  foreach ($case in $effectiveCases) {
    $caseRuns += Invoke-CaseRun -Case $case -BasePayload $payloadObj -Profile $profile -GatewayUrl $resolvedGatewayUrl -Headers $headers -TimeoutSec $timeoutSec -SkillId $SkillId -SkillVersion $SkillVersion -SkillIdField $resolvedSkillIdField -SkillVersionField $resolvedSkillVersionField -SensitiveMode $resolvedSensitiveMode -DisableFieldInjection:$DisableFieldInjection -Pretty:$Pretty
  }
  $sw.Stop()

  $caseRunSummary = Get-CaseRunSummary -CaseRuns $caseRuns
  $sampleRun = @($caseRuns | Where-Object { -not $_.skipped } | Select-Object -First 1)
  $sampleRun = if ($sampleRun.Count -gt 0) { $sampleRun[0] } else { $null }

  $out = [ordered]@{
    diagnostics = [ordered]@{
      gateway_url = $resolvedGatewayUrl
      output_dir = $OutputDir
      target_resolution = $resolvedTargetInfo
      adapter_kind = Get-AdapterKind -Profile $profile
      adapter_name = Get-AdapterName -Profile $profile
      adapter_supported_skill_shapes = @(Get-AdapterSupportedSkillShapes -Profile $profile)
      schema_version = [string](Get-NestedValue -Obj $profile -Path 'schema_version')
      profile_kind = [string](Get-NestedValue -Obj $profile -Path 'profile_kind')
      action_schema_required_fields = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.required_fields'))
      action_schema_recommended_fields = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.recommended_fields'))
      action_schema_variant_names = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.variant_names'))
      elapsed_ms = [int]$sw.ElapsedMilliseconds
      auth_env = $resolvedApiKeyEnv
      auth_header = $resolvedApiKeyHeader
      profile_file = if ($ProfileFile) { $ProfileFile } else { $null }
      case_matrix_file = if ($CaseMatrixFile) { $CaseMatrixFile } else { $null }
      case_count = $caseCount
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      executed_case_count = $caseRunSummary.executed_count
      pass_count = $caseRunSummary.pass_count
      fail_count = $caseRunSummary.fail_count
      review_needed_count = $caseRunSummary.review_needed_count
      skipped_count = $caseRunSummary.skipped_count
      overall_judgement = $caseRunSummary.overall_judgement
      http_status = if ($sampleRun) { $sampleRun.http_status } else { $null }
      gateway_code = if ($sampleRun) { $sampleRun.gateway_code } else { $null }
      message = if ($sampleRun) { $sampleRun.message } else { $null }
      timeout_sec = $timeoutSec
      coverage_complete = $coverageSummary.coverage_complete
      missing_required_tags = $coverageSummary.missing_required_tags
      action_complete = $actionSummary.action_complete
      missing_required_actions = $actionSummary.missing_required_actions
    }
    request = [ordered]@{
      payload_file = $PayloadFile
      skill_id = $SkillId
      skill_version = $SkillVersion
      field_injection = [ordered]@{
        enabled = (-not $DisableFieldInjection)
        skill_id_field = $resolvedSkillIdField
        skill_version_field = $resolvedSkillVersionField
      }
      sensitive_mode = $resolvedSensitiveMode
    }
    response = [ordered]@{
      parsed_json = if ($Pretty -and $sampleRun) { $sampleRun.response.parsed_json } else { $null }
      raw_text = if ($sampleRun -and $null -eq $sampleRun.response.parsed_json) { $sampleRun.response.raw_text } else { $null }
      result_payload = if ($sampleRun) { $sampleRun.response.result_payload } else { $null }
      version_meta = if ($sampleRun) { $sampleRun.response.version_meta } else { $null }
    }
    coverage = $coverageSummary
    action_coverage = $actionSummary
    case_plan = [ordered]@{
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      effective_case_count = $caseCount
      generation_mode = if ($manualCaseCount -gt 0) { 'manual_plus_auto_fill' } else { 'auto_only' }
      execution_mode = 'batch'
    }
    case_runs = @($caseRuns)
    error_info = $null
  }

  Save-Artifacts -Result $out -Profile $profile -Matrix $caseMatrix -Cases $effectiveCases -CaseRuns $caseRuns
  if ($Pretty) {
    $out | ConvertTo-Json -Depth 100
  } else {
    $out
  }
  exit 0
} catch {
  Write-Host ('批量执行失败: {0}' -f $_.Exception.Message)
  exit 1
}

$profile = $null
if (-not [string]::IsNullOrWhiteSpace($ProfileFile) -and (Test-Path -LiteralPath $ProfileFile)) {
  $profile = Read-JsonFile -Path $ProfileFile
}
Validate-ProfileSchema -Profile $profile

$caseMatrix = $null
if (-not [string]::IsNullOrWhiteSpace($CaseMatrixFile) -and (Test-Path -LiteralPath $CaseMatrixFile)) {
  $caseMatrix = Read-JsonFile -Path $CaseMatrixFile
}

$resolvedGatewayUrl = Resolve-Value -Primary $GatewayUrl -Secondary (Get-NestedValue -Obj $profile -Path 'transport.gateway_url') -Fallback ''
if ([string]::IsNullOrWhiteSpace([string]$resolvedGatewayUrl)) {
  Write-Host '缺少 GatewayUrl。请通过参数传入，或在 profile 的 transport.gateway_url 中配置。'
  exit 1
}

$resolvedApiKeyEnv = Resolve-Value -Primary $ApiKeyEnv -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_env') -Fallback 'API_KEY'
$resolvedApiKeyHeader = Resolve-Value -Primary $ApiKeyHeader -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_header') -Fallback 'Authorization'
$resolvedApiKeyPrefix = Resolve-Value -Primary $ApiKeyPrefix -Secondary (Get-NestedValue -Obj $profile -Path 'transport.auth_prefix') -Fallback 'Bearer '
$resolvedSkillIdField = Resolve-Value -Primary $SkillIdField -Secondary (Get-NestedValue -Obj $profile -Path 'fields.skill_id') -Fallback 'skill_id'
$resolvedSkillVersionField = Resolve-Value -Primary $SkillVersionField -Secondary (Get-NestedValue -Obj $profile -Path 'fields.skill_version') -Fallback '_skill_version'
$resolvedSensitiveMode = Resolve-Value -Primary $SensitiveMode -Secondary (Get-NestedValue -Obj $profile -Path 'risk.default_mode') -Fallback 'ask'
$resolvedSensitiveMode = [string]$resolvedSensitiveMode
if ([string]::IsNullOrWhiteSpace($resolvedSensitiveMode)) {
  $resolvedSensitiveMode = 'ask'
}
if ($resolvedSensitiveMode -notin @('ask', 'always_allow', 'always_block')) {
  Write-Host ("无效的 SensitiveMode: {0}" -f $resolvedSensitiveMode)
  exit 1
}

$timeoutSec = 60
$profileTimeout = Get-NestedValue -Obj $profile -Path 'transport.timeout_sec'
if ($null -ne $profileTimeout) {
  try { $timeoutSec = [int]$profileTimeout } catch {}
}

$apiKey = [Environment]::GetEnvironmentVariable($resolvedApiKeyEnv)
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  Write-Host ("当前未检测到本地环境变量 {0}，请先配置后再继续使用。" -f $resolvedApiKeyEnv)
  exit 1
}

if (-not (Test-Path -LiteralPath $PayloadFile)) {
  Write-Host ("未找到请求文件: {0}" -f $PayloadFile)
  exit 1
}

try {
  $payloadObj = Read-JsonFile -Path $PayloadFile
} catch {
  Write-Host '请求体 JSON 解析失败，请检查 payload 文件格式。'
  exit 1
}

if (-not $DisableFieldInjection) {
  $profileFieldInjection = Get-NestedValue -Obj $profile -Path 'field_injection.enabled'
  if ($null -ne $profileFieldInjection -and -not (Test-Truthy $profileFieldInjection)) {
    $DisableFieldInjection = $true
  }
}

if (-not $DisableFieldInjection) {
  Set-OrAddProperty -Obj $payloadObj -Name $resolvedSkillIdField -Value $SkillId
  Set-OrAddProperty -Obj $payloadObj -Name $resolvedSkillVersionField -Value $SkillVersion
}

$isSensitive = Is-SensitivePayload -PayloadObj $payloadObj -Profile $profile
if ($isSensitive) {
  if ($resolvedSensitiveMode -eq 'always_block') {
    Write-Host '检测到敏感测试（写操作或等价副作用），当前模式为 always_block，已中止执行。'
    exit 2
  }
  if ($resolvedSensitiveMode -eq 'ask') {
    Write-Host '检测到敏感测试（写操作或等价副作用）。'
    Write-Host ("SkillId: {0}" -f $SkillId)
    Write-Host ("Gateway: {0}" -f $resolvedGatewayUrl)
    Write-Host '请选择执行方式：'
    Write-Host '  1) 继续执行写操作'
    Write-Host '  2) 取消（不执行）'
    $ans = Read-Host '请输入 1 或 2'
    if ($ans -ne '1') {
      Write-Host '已取消本次敏感测试。'
      exit 2
    }
  }
}

$headers = @{
  'Content-Type' = 'application/json'
}
$headers[$resolvedApiKeyHeader] = ("{0}{1}" -f $resolvedApiKeyPrefix, $apiKey)

$body = $payloadObj | ConvertTo-Json -Depth 100
$sw = [Diagnostics.Stopwatch]::StartNew()
$effectiveCases = Get-EffectiveCaseArray -Profile $profile -Matrix $caseMatrix
$manualCaseCount = (Get-CaseArray -Matrix $caseMatrix).Count
$generatedCaseCount = (@(Get-GeneratedCasesFromActions -Profile $profile)).Count
$caseCount = $effectiveCases.Count
$coverageSummary = Get-CoverageSummary -Profile $profile -Cases $effectiveCases
$actionSummary = Get-ActionCoverageSummary -Profile $profile -Cases $effectiveCases

try {
  $resp = Invoke-WebRequest -Uri $resolvedGatewayUrl -Method Post -Headers $headers -Body $body -TimeoutSec $timeoutSec
  $sw.Stop()

  $httpStatus = [int]$resp.StatusCode
  $parsed = Parse-ResponseText -Text $resp.Content

  $responseMapping = Get-ResponseMapping -Profile $profile
  $gatewayCodePaths = @($responseMapping.gateway_code_paths)
  $messagePaths = @($responseMapping.message_paths)
  $resultPaths = @($responseMapping.result_paths)
  $versionPaths = @($responseMapping.version_paths)

  $gatewayCode = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $gatewayCodePaths } else { $null }
  $message = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $messagePaths } else { $null }
  $resultPayload = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $resultPaths } else { $null }
  $versionMeta = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $versionPaths } else { $null }
  if ($null -eq $resultPayload -and $parsed) {
    $resultPayload = $parsed
  }

  $out = [ordered]@{
    diagnostics = [ordered]@{
      gateway_url = $resolvedGatewayUrl
      output_dir = $OutputDir
      target_resolution = $resolvedTargetInfo
      http_status = $httpStatus
      elapsed_ms = [int]$sw.ElapsedMilliseconds
      gateway_code = $gatewayCode
      message = $message
      auth_env = $resolvedApiKeyEnv
      auth_header = $resolvedApiKeyHeader
      profile_file = if ($ProfileFile) { $ProfileFile } else { $null }
      case_matrix_file = if ($CaseMatrixFile) { $CaseMatrixFile } else { $null }
      case_count = $caseCount
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      timeout_sec = $timeoutSec
      coverage_complete = $coverageSummary.coverage_complete
      missing_required_tags = $coverageSummary.missing_required_tags
      action_complete = $actionSummary.action_complete
      missing_required_actions = $actionSummary.missing_required_actions
    }
    request = [ordered]@{
      payload_file = $PayloadFile
      skill_id = $SkillId
      skill_version = $SkillVersion
      field_injection = [ordered]@{
        enabled = (-not $DisableFieldInjection)
        skill_id_field = $resolvedSkillIdField
        skill_version_field = $resolvedSkillVersionField
      }
      sensitive_mode = $resolvedSensitiveMode
    }
    response = [ordered]@{
      parsed_json = if ($Pretty) { $parsed } else { $null }
      raw_text = if ($null -eq $parsed) { $resp.Content } else { $null }
      result_payload = $resultPayload
      version_meta = $versionMeta
    }
    coverage = $coverageSummary
    action_coverage = $actionSummary
    case_plan = [ordered]@{
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      effective_case_count = $caseCount
      generation_mode = if ($manualCaseCount -gt 0) { 'manual_plus_auto_fill' } else { 'auto_only' }
    }
    error_info = $null
  }

  Save-Artifacts -Result $out -Profile $profile -Matrix $caseMatrix -Cases $effectiveCases
  if ($Pretty) {
    $out | ConvertTo-Json -Depth 100
  } else {
    $out
  }
} catch {
  $sw.Stop()

  $status = $null
  $rawText = $null
  $parsed = $null

  if ($_.Exception.Response) {
    try {
      $status = [int]$_.Exception.Response.StatusCode.value__
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $rawText = $reader.ReadToEnd()
      $reader.Close()
      $parsed = Parse-ResponseText -Text $rawText
    } catch {}
  }

  $responseMapping = Get-ResponseMapping -Profile $profile
  $gatewayCodePaths = @($responseMapping.gateway_code_paths)
  $messagePaths = @($responseMapping.message_paths)
  $resultPaths = @($responseMapping.result_paths)
  $versionPaths = @($responseMapping.version_paths)

  $out = [ordered]@{
    diagnostics = [ordered]@{
      gateway_url = $resolvedGatewayUrl
      output_dir = $OutputDir
      schema_version = [string](Get-NestedValue -Obj $profile -Path 'schema_version')
      profile_kind = [string](Get-NestedValue -Obj $profile -Path 'profile_kind')
      action_schema_required_fields = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.required_fields'))
      action_schema_recommended_fields = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.recommended_fields'))
      action_schema_variant_names = @(Get-StringArray (Get-NestedValue -Obj $profile -Path 'action_schema.variant_names'))
      http_status = $status
      elapsed_ms = [int]$sw.ElapsedMilliseconds
      gateway_code = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $gatewayCodePaths } else { $null }
      message = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $messagePaths } else { $null }
      auth_env = $resolvedApiKeyEnv
      auth_header = $resolvedApiKeyHeader
      profile_file = if ($ProfileFile) { $ProfileFile } else { $null }
      case_matrix_file = if ($CaseMatrixFile) { $CaseMatrixFile } else { $null }
      case_count = $caseCount
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      timeout_sec = $timeoutSec
      coverage_complete = $coverageSummary.coverage_complete
      missing_required_tags = $coverageSummary.missing_required_tags
      action_complete = $actionSummary.action_complete
      missing_required_actions = $actionSummary.missing_required_actions
    }
    request = [ordered]@{
      payload_file = $PayloadFile
      skill_id = $SkillId
      skill_version = $SkillVersion
      field_injection = [ordered]@{
        enabled = (-not $DisableFieldInjection)
        skill_id_field = $resolvedSkillIdField
        skill_version_field = $resolvedSkillVersionField
      }
      sensitive_mode = $resolvedSensitiveMode
    }
    response = [ordered]@{
      parsed_json = if ($Pretty) { $parsed } else { $null }
      raw_text = if ($rawText) { $rawText } else { $null }
      result_payload = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $resultPaths } else { $null }
      version_meta = if ($parsed) { Resolve-From-Paths -Obj $parsed -Paths $versionPaths } else { $null }
    }
    coverage = $coverageSummary
    action_coverage = $actionSummary
    case_plan = [ordered]@{
      manual_case_count = $manualCaseCount
      generated_case_count = $generatedCaseCount
      effective_case_count = $caseCount
      generation_mode = if ($manualCaseCount -gt 0) { 'manual_plus_auto_fill' } else { 'auto_only' }
    }
    error_info = [ordered]@{
      type = if ($status) { 'http_error' } else { 'network_or_unknown_error' }
      detail = if ($parsed) { $parsed } elseif ($rawText) { $rawText } else { $_.Exception.Message }
      response_excerpt = Get-TruncatedText -Text $rawText -MaxLength 500
      readable = Get-FriendlyErrorSummary -HttpStatus $status -RawText $rawText
      example = [ordered]@{
        trigger = '输入缺少必填字段或字段值越界'
        observed = '接口返回了错误，但用例不知道具体错在什么地方'
        expected = '返回字段级可读错误，说明哪个字段不合法以及如何修正'
      }
    }
  }

  Save-Artifacts -Result $out -Profile $profile -Matrix $caseMatrix -Cases $effectiveCases
  if ($Pretty) {
    $out | ConvertTo-Json -Depth 100
  } else {
    $out
  }
  exit 1
}

