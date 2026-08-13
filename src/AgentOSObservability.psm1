Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:agentOSObservationMetricNames = @('duration_ms', 'model_calls', 'input_tokens', 'output_tokens', 'cost_microunits')

function Read-AgentOSObservationJson {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Agent OS observation JSON file not found: $LiteralPath"
    }
    return Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -Depth 50 -ErrorAction Stop
}

function Assert-AgentOSObservationJsonTextSchema {
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [Parameter(Mandatory)][string]$SchemaName
    )

    $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'schemas' $SchemaName)
    try {
        $valid = $JsonText | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch {
        throw "Agent OS observation JSON failed schema validation for $SchemaName. $($_.Exception.Message)"
    }
    if (-not $valid) {
        throw "Agent OS observation JSON failed schema validation for $SchemaName."
    }
}

function Assert-AgentOSObservationNoCredentialLikeText {
    param([Parameter(Mandatory)][string]$Text)

    $patterns = @(
        '(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b',
        '(?i)(?:\bapi[-_ ]?key\b|\baccess[-_ ]?token\b|\brefresh[-_ ]?token\b|\bclient[-_ ]?secret\b|\bsecret[-_ ]?key\b|\bsecret\b|\btoken\b|\bpassword\b|\bpasswd\b|\bcookie\b|\bauthorization\b|密码|口令|密钥|令牌|凭据)\s*[:=：]\s*\S+',
        '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*',
        '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            throw 'Agent OS observation refuses to persist credential-like text.'
        }
    }
}

function Read-AgentOSObservationBoundJson {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$SchemaName
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Agent OS observation JSON file not found: $LiteralPath"
    }
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 16777216) {
            throw 'Agent OS observation JSON exceeds the 16 MiB input limit.'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'Agent OS observation JSON ended before all bytes were read.' }
            $offset += $read
        }
    }
    finally {
        $stream.Dispose()
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    Assert-AgentOSObservationNoCredentialLikeText -Text $text
    Assert-AgentOSObservationJsonTextSchema -JsonText $text -SchemaName $SchemaName
    return [pscustomobject]@{
        text = $text
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        document = $text | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    }
}

function Get-AgentOSObservationSubjectContractInfo {
    param([Parameter(Mandatory)][string]$Kind)

    switch ($Kind) {
        'agent_os_task' { return [pscustomobject]@{ schema = 'agent_os_runtime_task.schema.json'; id_property = 'task_id' } }
        'worker_job' { return [pscustomobject]@{ schema = 'agent_os_worker_input.schema.json'; id_property = 'job_id' } }
        'graph' { return [pscustomobject]@{ schema = 'agent_os_graph_contract.schema.json'; id_property = 'graph_id' } }
        'project_task' { return [pscustomobject]@{ schema = 'task_contract.schema.json'; id_property = 'task_id' } }
        default { throw "Agent OS observation subject kind is unsupported: $Kind" }
    }
}

function Read-AgentOSObservationSubjectContract {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$SubjectId
    )

    $info = Get-AgentOSObservationSubjectContractInfo -Kind $Kind
    $source = Read-AgentOSObservationBoundJson -LiteralPath $LiteralPath -SchemaName $info.schema
    $actualId = [string]$source.document.($info.id_property)
    if ($actualId -ne $SubjectId) {
        throw "Agent OS observation subject ID does not match its $Kind contract."
    }
    return $source
}

function Get-AgentOSObservationFileSha256 {
    param([Parameter(Mandatory)][string]$LiteralPath)

    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-AgentOSObservationTextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function ConvertTo-AgentOSObservationJson {
    param([Parameter(Mandatory)]$Value)

    return $Value | ConvertTo-Json -Depth 50
}

function ConvertTo-AgentOSObservationDateText {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToString('o') }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        throw 'Agent OS observation timestamp is invalid.'
    }
    return $parsed.ToString('o')
}

function Write-AgentOSObservationCreateNew {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Text
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Test-AgentOSObservationPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AgentOSObservationItemIsNotReparsePoint {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Agent OS observation path cannot be a reparse point or junction: $LiteralPath"
    }
}

function Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $current = [IO.Path]::GetFullPath($LiteralPath)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            Assert-AgentOSObservationItemIsNotReparsePoint -LiteralPath $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-AgentOSObservationStageGraph {
    param([Parameter(Mandatory)]$Stages)

    $byId = @{}
    foreach ($stage in @($Stages)) {
        $stageId = [string]$stage.stage_id
        if ($byId.ContainsKey($stageId)) {
            throw "Agent OS observation stage ID '$stageId' is duplicated."
        }
        $gateIds = @{}
        foreach ($gate in @($stage.quality_gates)) {
            $gateId = [string]$gate.gate_id
            if ($gateIds.ContainsKey($gateId)) {
                throw "Agent OS observation quality gate '$gateId' is duplicated in stage '$stageId'."
            }
            $gateIds[$gateId] = $true
        }
        $byId[$stageId] = $stage
    }
    $remaining = @{}
    foreach ($stage in @($Stages)) {
        $stageId = [string]$stage.stage_id
        $dependencies = @($stage.depends_on | ForEach-Object { [string]$_ })
        foreach ($dependency in $dependencies) {
            if (-not $byId.ContainsKey($dependency)) {
                throw "Agent OS observation stage '$stageId' depends on unknown stage '$dependency'."
            }
        }
        $remaining[$stageId] = $dependencies
    }
    while ($remaining.Count -gt 0) {
        $ready = @($remaining.Keys | Where-Object { @($remaining[$_]).Count -eq 0 })
        if ($ready.Count -eq 0) {
            throw 'Agent OS observation stage graph contains a cycle.'
        }
        foreach ($stageId in $ready) {
            $remaining.Remove($stageId)
            foreach ($otherId in @($remaining.Keys)) {
                $remaining[$otherId] = @($remaining[$otherId] | Where-Object { $_ -ne $stageId })
            }
        }
    }
}

function ConvertTo-AgentOSObservationStableHashValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -is [string]) {
        if ($Value -match '^\d{4}-\d{2}-\d{2}T') {
            $parsed = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($Value, [ref]$parsed)) {
                return $parsed.ToString('o')
            }
        }
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $mapped = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $mapped[[string]$key] = ConvertTo-AgentOSObservationStableHashValue -Value $Value[$key]
        }
        return $mapped
    }
    if ($Value -is [pscustomobject]) {
        $mapped = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $mapped[$property.Name] = ConvertTo-AgentOSObservationStableHashValue -Value $property.Value
        }
        return $mapped
    }
    if ($Value -is [Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-AgentOSObservationStableHashValue -Value $_ })
    }
    return $Value
}

function Get-AgentOSObservationEventHash {
    param([Parameter(Mandatory)]$Event)

    $hashInput = [ordered]@{}
    foreach ($property in $Event.PSObject.Properties) {
        if ($property.Name -ne 'event_sha256') {
            $hashInput[$property.Name] = ConvertTo-AgentOSObservationStableHashValue -Value $property.Value
        }
    }
    $json = (ConvertTo-AgentOSObservationJson -Value $hashInput) -replace "`r`n", "`n"
    return Get-AgentOSObservationTextSha256 -Text $json
}

function New-AgentOSObservationEvent {
    param(
        [Parameter(Mandatory)][string]$ObservationId,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$PreviousSha256,
        [Parameter(Mandatory)]$Details,
        [string]$StageId = ''
    )

    $event = [pscustomobject][ordered]@{
        schema_version = '0.1'
        observation_id = $ObservationId
        sequence = $Sequence
        occurred_at = [DateTimeOffset]::Now.ToString('o')
        event_type = $EventType
        stage_id = $StageId
        details = $Details
        prev_event_sha256 = $PreviousSha256
        event_sha256 = ''
    }
    $event.event_sha256 = Get-AgentOSObservationEventHash -Event $event
    return $event
}

function New-AgentOSObservationZeroMetrics {
    return [pscustomobject][ordered]@{
        duration_ms = [int64]0
        model_calls = [int64]0
        input_tokens = [int64]0
        output_tokens = [int64]0
        cost_microunits = [int64]0
    }
}

function Assert-AgentOSObservationMetricShape {
    param([Parameter(Mandatory)]$Metrics)

    $required = $script:agentOSObservationMetricNames
    if ($null -eq $Metrics) { throw 'observation metrics are missing' }
    $names = @($Metrics.PSObject.Properties.Name)
    if (@($names | Where-Object { $_ -notin $required }).Count -gt 0 -or
        @($required | Where-Object { $_ -notin $names }).Count -gt 0) {
        throw 'observation metrics have an invalid shape'
    }
    foreach ($name in $required) {
        $value = $Metrics.$name
        $isInteger = $value -is [sbyte] -or $value -is [byte] -or
            $value -is [int16] -or $value -is [uint16] -or
            $value -is [int32] -or $value -is [uint32] -or
            $value -is [int64] -or $value -is [uint64]
        if (-not $isInteger -or [decimal]$value -lt 0 -or [decimal]$value -gt 1000000000000000) {
            throw "observation metric $name is invalid"
        }
    }
}

function Assert-AgentOSObservationExactProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Names)

    if ($null -eq $Value) { throw 'observation event details are missing' }
    $actual = @($Value.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $Names }).Count -gt 0 -or
        @($Names | Where-Object { $_ -notin $actual }).Count -gt 0) {
        throw 'observation event details have an invalid shape'
    }
}

function Assert-AgentOSObservationSha256 {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)

    if ([string]$Value -notmatch '^[A-F0-9]{64}$') { throw "$Name is invalid" }
}

function Assert-AgentOSObservationEvidenceArrayShape {
    param([Parameter(Mandatory)]$Evidence)

    foreach ($reference in @($Evidence)) {
        Assert-AgentOSObservationExactProperties -Value $reference -Names @('path', 'sha256')
        if ([string]::IsNullOrWhiteSpace([string]$reference.path)) { throw 'evidence path is invalid' }
        Assert-AgentOSObservationSha256 -Value $reference.sha256 -Name 'evidence hash'
    }
}

function Assert-AgentOSObservationResultDetailsShape {
    param([Parameter(Mandatory)]$Details)

    Assert-AgentOSObservationExactProperties -Value $Details -Names @(
        'result_sha256', 'finished_at', 'usage', 'quality_measurements', 'cost_evidence',
        'failure_reasons', 'exceeded_dimensions', 'quality_failures'
    )
    Assert-AgentOSObservationSha256 -Value $Details.result_sha256 -Name 'result hash'
    ConvertTo-AgentOSObservationDateText -Value $Details.finished_at | Out-Null
    Assert-AgentOSObservationMetricShape -Metrics $Details.usage
    Assert-AgentOSObservationEvidenceArrayShape -Evidence $Details.cost_evidence
    foreach ($measurement in @($Details.quality_measurements)) {
        Assert-AgentOSObservationExactProperties -Value $measurement -Names @('gate_id', 'metric', 'unit', 'value', 'evidence')
        if ([string]$measurement.gate_id -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
            [string]$measurement.metric -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
            [string]$measurement.unit -notmatch '^[A-Za-z0-9][A-Za-z0-9._%/-]{0,31}$') {
            throw 'quality measurement identity is invalid'
        }
        $value = $measurement.value
        $isInteger = $value -is [int32] -or $value -is [int64]
        if (-not $isInteger -or [decimal]$value -lt -1000000000000000 -or [decimal]$value -gt 1000000000000000) {
            throw 'quality measurement value is invalid'
        }
        Assert-AgentOSObservationEvidenceArrayShape -Evidence $measurement.evidence
    }
    foreach ($reason in @($Details.failure_reasons)) {
        if ([string]::IsNullOrWhiteSpace([string]$reason)) { throw 'failure reason is invalid' }
    }
    foreach ($dimension in @($Details.exceeded_dimensions)) {
        if ([string]$dimension -notin $script:agentOSObservationMetricNames) { throw 'exceeded budget dimension is invalid' }
    }
    foreach ($failure in @($Details.quality_failures)) {
        if ([string]::IsNullOrWhiteSpace([string]$failure)) { throw 'quality failure is invalid' }
    }
}

function Add-AgentOSObservationMetrics {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    $sum = [ordered]@{}
    foreach ($name in $script:agentOSObservationMetricNames) {
        $sum[$name] = [int64]$Left.$name + [int64]$Right.$name
    }
    return [pscustomobject]$sum
}

function Subtract-AgentOSObservationMetrics {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    $difference = [ordered]@{}
    foreach ($name in $script:agentOSObservationMetricNames) {
        $difference[$name] = [int64]$Left.$name - [int64]$Right.$name
    }
    return [pscustomobject]$difference
}

function Get-AgentOSObservationExceededBudgets {
    param([Parameter(Mandatory)]$Metrics, [Parameter(Mandatory)]$Budgets)

    $exceeded = @()
    foreach ($name in $script:agentOSObservationMetricNames) {
        if ([int64]$Metrics.$name -gt [int64]$Budgets.$name) {
            $exceeded += $name
        }
    }
    return @($exceeded)
}

function New-AgentOSObservationResult {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$ObservationSha256,
        [string]$LedgerIntegrity = 'valid',
        [string[]]$LedgerErrors = @(),
        [bool]$SnapshotRewritten = $false
    )

    $stageStates = @($Snapshot.stages)
    $counts = [ordered]@{ pending = 0; running = 0; succeeded = 0; failed = 0; blocked = 0 }
    foreach ($stage in $stageStates) {
        $counts[[string]$stage.state] = [int]$counts[[string]$stage.state] + 1
    }
    return [pscustomobject][ordered]@{
        observation_id = [string]$Contract.observation_id
        observation_key = [string]$Contract.observation_key
        observation_path = $ObservationPath
        contract_path = Join-Path $ObservationPath 'observation.json'
        ledger_path = Join-Path $ObservationPath 'ledger.jsonl'
        snapshot_path = Join-Path $ObservationPath 'snapshot.json'
        observation_sha256 = $ObservationSha256
        state = [string]$Snapshot.state
        stage_counts = [pscustomobject]$counts
        actual_totals = $Snapshot.actual_totals
        reserved_totals = $Snapshot.reserved_totals
        ledger_integrity = $LedgerIntegrity
        ledger_errors = @($LedgerErrors)
        ledger_head_sha256 = [string]$Snapshot.ledger_head_sha256
        last_trusted_sequence = [int]$Snapshot.last_trusted_sequence
        snapshot_rewritten = $SnapshotRewritten
    }
}

function Get-AgentOSObservationContext {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $fullRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $fullObservationPath = [IO.Path]::GetFullPath($ObservationPath)
    if (-not (Test-AgentOSObservationPathWithinRoot -Path $fullObservationPath -Root $fullRuntimeRoot)) {
        throw 'Agent OS observation path must stay within RuntimeRoot.'
    }
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $fullRuntimeRoot
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $fullObservationPath
    if (-not (Test-Path -LiteralPath $fullObservationPath -PathType Container)) {
        throw 'Agent OS observation directory does not exist.'
    }
    $contractPath = Join-Path $fullObservationPath 'observation.json'
    $ledgerPath = Join-Path $fullObservationPath 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        throw 'Agent OS observation Ledger does not exist.'
    }
    $contractSource = Read-AgentOSObservationBoundJson -LiteralPath $contractPath -SchemaName 'agent_os_observability_contract.schema.json'
    $contract = $contractSource.document
    if ([string]$contract.observation_id -ne (Split-Path -Leaf $fullObservationPath)) {
        throw 'Agent OS observation directory does not match the immutable observation ID.'
    }
    $subjectContractPath = [IO.Path]::GetFullPath([string]$contract.subject.contract_path)
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $subjectContractPath
    $subjectSource = Read-AgentOSObservationSubjectContract `
        -LiteralPath $subjectContractPath `
        -Kind ([string]$contract.subject.kind) `
        -SubjectId ([string]$contract.subject.subject_id)
    if ([string]$subjectSource.sha256 -ne [string]$contract.subject.contract_sha256) {
        throw 'Agent OS observation subject contract drifted.'
    }
    return [pscustomobject]@{
        observation_path = $fullObservationPath
        contract_path = $contractPath
        ledger_path = $ledgerPath
        snapshot_path = Join-Path $fullObservationPath 'snapshot.json'
        contract = $contract
        observation_sha256 = [string]$contractSource.sha256
    }
}

function Get-AgentOSObservationTrustedLedger {
    param([Parameter(Mandatory)]$Context)

    $events = @()
    $errors = @()
    $expectedSequence = 1
    $previousSha256 = '0' * 64
    $stageStates = @{}
    $stageStartedAt = @{}
    $stageReservations = @{}
    $stages = @{}
    foreach ($stage in @($Context.contract.stages)) {
        $stageId = [string]$stage.stage_id
        $stageStates[$stageId] = 'pending'
        $stages[$stageId] = $stage
    }
    $actual = New-AgentOSObservationZeroMetrics
    $reserved = New-AgentOSObservationZeroMetrics
    $terminal = $false
    foreach ($line in @(Get-Content -LiteralPath $Context.ledger_path -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try {
            $event = $line | ConvertFrom-Json -Depth 50 -ErrorAction Stop
            $names = @($event.PSObject.Properties.Name)
            $requiredNames = @('schema_version', 'observation_id', 'sequence', 'occurred_at', 'event_type', 'stage_id', 'details', 'prev_event_sha256', 'event_sha256')
            $sequenceIsInteger = $event.sequence -is [int32] -or $event.sequence -is [int64]
            if (@($names | Where-Object { $_ -notin $requiredNames }).Count -gt 0 -or
                @($requiredNames | Where-Object { $_ -notin $names }).Count -gt 0 -or
                [string]$event.schema_version -ne '0.1' -or
                [string]$event.observation_id -ne [string]$Context.contract.observation_id -or
                -not $sequenceIsInteger -or [int64]$event.sequence -ne $expectedSequence -or
                [string]$event.prev_event_sha256 -ne $previousSha256 -or
                [string]$event.event_sha256 -ne (Get-AgentOSObservationEventHash -Event $event)) {
                throw 'shape, observation, sequence, previous hash, or event hash check failed'
            }
            ConvertTo-AgentOSObservationDateText -Value $event.occurred_at | Out-Null
            $eventType = [string]$event.event_type
            $stageId = [string]$event.stage_id
            switch ($eventType) {
                'observation_initialized' {
                    Assert-AgentOSObservationExactProperties -Value $event.details -Names @('observation_sha256')
                    if ($expectedSequence -ne 1 -or $stageId -or
                        [string]$event.details.observation_sha256 -ne [string]$Context.observation_sha256) {
                        throw 'initialization event is not bound to the observation contract'
                    }
                }
                'stage_started' {
                    if ($terminal -or -not $stages.ContainsKey($stageId) -or $stageStates[$stageId] -ne 'pending') {
                        throw 'stage_started is invalid for the current stage state'
                    }
                    foreach ($dependency in @($stages[$stageId].depends_on)) {
                        if ($stageStates[[string]$dependency] -ne 'succeeded') { throw 'stage dependency is not succeeded' }
                    }
                    Assert-AgentOSObservationExactProperties -Value $event.details -Names @('request_sha256', 'started_at', 'reservation', 'exceeded_dimensions')
                    Assert-AgentOSObservationMetricShape -Metrics $event.details.reservation
                    $startedAt = ConvertTo-AgentOSObservationDateText -Value $event.details.started_at
                    Assert-AgentOSObservationSha256 -Value $event.details.request_sha256 -Name 'request hash'
                    $projected = Add-AgentOSObservationMetrics -Left $actual -Right $reserved
                    $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.reservation
                    $recalculatedExceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets)
                    if ($recalculatedExceeded.Count -ne 0 -or @($event.details.exceeded_dimensions).Count -ne 0) {
                        throw 'started stage would exceed its contract budget'
                    }
                    $stageStates[$stageId] = 'running'
                    $stageStartedAt[$stageId] = $startedAt
                    $stageReservations[$stageId] = $event.details.reservation
                    $reserved = Add-AgentOSObservationMetrics -Left $reserved -Right $event.details.reservation
                }
                'stage_blocked_budget' {
                    if ($terminal -or -not $stages.ContainsKey($stageId)) { throw 'stage_blocked_budget is invalid' }
                    $hasUsage = $null -ne $event.details.PSObject.Properties['usage']
                    if ($hasUsage) {
                        if ($stageStates[$stageId] -ne 'running') { throw 'actual budget block requires a running stage' }
                        Assert-AgentOSObservationResultDetailsShape -Details $event.details
                        $finishedAt = ConvertTo-AgentOSObservationDateText -Value $event.details.finished_at
                        $elapsed = [int64][Math]::Round(([DateTimeOffset]::Parse($finishedAt) - [DateTimeOffset]::Parse([string]$stageStartedAt[$stageId])).TotalMilliseconds)
                        if ($elapsed -lt 0 -or $elapsed -ne [int64]$event.details.usage.duration_ms) { throw 'stage duration is inconsistent' }
                        $otherReserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageReservations[$stageId]
                        $projected = Add-AgentOSObservationMetrics -Left $actual -Right $otherReserved
                        $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.usage
                        $recalculatedExceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets)
                        if ($recalculatedExceeded.Count -eq 0 -or
                            (ConvertTo-AgentOSObservationJson -Value $recalculatedExceeded) -ne (ConvertTo-AgentOSObservationJson -Value @($event.details.exceeded_dimensions))) {
                            throw 'actual budget block does not match the contract budget'
                        }
                        Assert-AgentOSObservationAcceptedResultEvidence -Context $Context -Details $event.details
                        $qualityFailures = @(Get-AgentOSObservationRecalculatedQualityFailures -Context $Context -StageContract $stages[$stageId] -Details $event.details)
                        if ((ConvertTo-AgentOSObservationJson -Value $qualityFailures) -ne (ConvertTo-AgentOSObservationJson -Value @($event.details.quality_failures))) {
                            throw 'quality failures do not match the contract gates'
                        }
                        $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                        $reserved = $otherReserved
                    }
                    else {
                        if ($stageStates[$stageId] -ne 'pending') { throw 'reservation budget block requires a pending stage' }
                        Assert-AgentOSObservationExactProperties -Value $event.details -Names @('request_sha256', 'started_at', 'reservation', 'exceeded_dimensions')
                        Assert-AgentOSObservationMetricShape -Metrics $event.details.reservation
                        ConvertTo-AgentOSObservationDateText -Value $event.details.started_at | Out-Null
                        Assert-AgentOSObservationSha256 -Value $event.details.request_sha256 -Name 'request hash'
                        $projected = Add-AgentOSObservationMetrics -Left $actual -Right $reserved
                        $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.reservation
                        $recalculatedExceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets)
                        if ($recalculatedExceeded.Count -eq 0 -or
                            (ConvertTo-AgentOSObservationJson -Value $recalculatedExceeded) -ne (ConvertTo-AgentOSObservationJson -Value @($event.details.exceeded_dimensions))) {
                            throw 'reservation budget block does not match the contract budget'
                        }
                    }
                    $stageStates[$stageId] = 'blocked'
                    $terminal = $true
                }
                'stage_succeeded' {
                    if ($terminal -or -not $stages.ContainsKey($stageId) -or $stageStates[$stageId] -ne 'running') { throw 'stage_succeeded requires a running stage' }
                    Assert-AgentOSObservationResultDetailsShape -Details $event.details
                    if (@($event.details.exceeded_dimensions).Count -gt 0 -or @($event.details.quality_failures).Count -gt 0 -or @($event.details.failure_reasons).Count -gt 0) {
                        throw 'succeeded stage contains failure details'
                    }
                    $finishedAt = ConvertTo-AgentOSObservationDateText -Value $event.details.finished_at
                    $elapsed = [int64][Math]::Round(([DateTimeOffset]::Parse($finishedAt) - [DateTimeOffset]::Parse([string]$stageStartedAt[$stageId])).TotalMilliseconds)
                    if ($elapsed -lt 0 -or $elapsed -ne [int64]$event.details.usage.duration_ms) { throw 'stage duration is inconsistent' }
                    $otherReserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageReservations[$stageId]
                    $projected = Add-AgentOSObservationMetrics -Left $actual -Right $otherReserved
                    $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.usage
                    if (@(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets).Count -gt 0) { throw 'succeeded stage exceeds the contract budget' }
                    Assert-AgentOSObservationAcceptedResultEvidence -Context $Context -Details $event.details
                    $qualityFailures = @(Get-AgentOSObservationRecalculatedQualityFailures -Context $Context -StageContract $stages[$stageId] -Details $event.details)
                    if ($qualityFailures.Count -gt 0) { throw 'succeeded stage fails a contract quality gate' }
                    $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                    $reserved = $otherReserved
                    $stageStates[$stageId] = 'succeeded'
                }
                'stage_failed' {
                    if ($terminal -or -not $stages.ContainsKey($stageId) -or $stageStates[$stageId] -ne 'running') { throw 'stage_failed requires a running stage' }
                    Assert-AgentOSObservationResultDetailsShape -Details $event.details
                    if (@($event.details.failure_reasons).Count -eq 0 -or @($event.details.exceeded_dimensions).Count -gt 0) { throw 'failed stage reason is inconsistent' }
                    $finishedAt = ConvertTo-AgentOSObservationDateText -Value $event.details.finished_at
                    $elapsed = [int64][Math]::Round(([DateTimeOffset]::Parse($finishedAt) - [DateTimeOffset]::Parse([string]$stageStartedAt[$stageId])).TotalMilliseconds)
                    if ($elapsed -lt 0 -or $elapsed -ne [int64]$event.details.usage.duration_ms) { throw 'stage duration is inconsistent' }
                    $otherReserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageReservations[$stageId]
                    $projected = Add-AgentOSObservationMetrics -Left $actual -Right $otherReserved
                    $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.usage
                    if (@(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets).Count -gt 0) { throw 'failed stage should have been a budget block' }
                    Assert-AgentOSObservationAcceptedResultEvidence -Context $Context -Details $event.details
                    $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                    $reserved = $otherReserved
                    $stageStates[$stageId] = 'failed'
                    $terminal = $true
                }
                'stage_blocked_quality' {
                    if ($terminal -or -not $stages.ContainsKey($stageId) -or $stageStates[$stageId] -ne 'running') { throw 'stage_blocked_quality requires a running stage' }
                    Assert-AgentOSObservationResultDetailsShape -Details $event.details
                    if (@($event.details.quality_failures).Count -eq 0 -or @($event.details.exceeded_dimensions).Count -gt 0 -or @($event.details.failure_reasons).Count -gt 0) {
                        throw 'quality block details are inconsistent'
                    }
                    $finishedAt = ConvertTo-AgentOSObservationDateText -Value $event.details.finished_at
                    $elapsed = [int64][Math]::Round(([DateTimeOffset]::Parse($finishedAt) - [DateTimeOffset]::Parse([string]$stageStartedAt[$stageId])).TotalMilliseconds)
                    if ($elapsed -lt 0 -or $elapsed -ne [int64]$event.details.usage.duration_ms) { throw 'stage duration is inconsistent' }
                    $otherReserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageReservations[$stageId]
                    $projected = Add-AgentOSObservationMetrics -Left $actual -Right $otherReserved
                    $projected = Add-AgentOSObservationMetrics -Left $projected -Right $event.details.usage
                    if (@(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $Context.contract.budgets).Count -gt 0) { throw 'quality block should have been a budget block' }
                    Assert-AgentOSObservationAcceptedResultEvidence -Context $Context -Details $event.details
                    $qualityFailures = @(Get-AgentOSObservationRecalculatedQualityFailures -Context $Context -StageContract $stages[$stageId] -Details $event.details)
                    if ($qualityFailures.Count -eq 0 -or
                        (ConvertTo-AgentOSObservationJson -Value $qualityFailures) -ne (ConvertTo-AgentOSObservationJson -Value @($event.details.quality_failures))) {
                        throw 'quality block does not match the contract gates'
                    }
                    $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                    $reserved = $otherReserved
                    $stageStates[$stageId] = 'blocked'
                    $terminal = $true
                }
                'evaluation_passed' {
                    Assert-AgentOSObservationExactProperties -Value $event.details -Names @('actual_totals', 'stage_count')
                    if ($terminal -or $stageId -or @($stageStates.Values | Where-Object { $_ -ne 'succeeded' }).Count -gt 0) {
                        throw 'evaluation_passed requires every stage to have succeeded'
                    }
                    Assert-AgentOSObservationMetricShape -Metrics $event.details.actual_totals
                    $stageCountIsInteger = $event.details.stage_count -is [int32] -or $event.details.stage_count -is [int64]
                    if (-not $stageCountIsInteger -or [int64]$event.details.stage_count -ne $stages.Count -or
                        (ConvertTo-AgentOSObservationJson -Value $event.details.actual_totals) -ne (ConvertTo-AgentOSObservationJson -Value $actual)) {
                        throw 'evaluation totals do not match trusted stage events'
                    }
                    if (@(Get-AgentOSObservationExceededBudgets -Metrics $actual -Budgets $Context.contract.budgets).Count -gt 0) {
                        throw 'evaluation_passed exceeds the contract budget'
                    }
                    $terminal = $true
                }
                default { throw "unsupported event type: $eventType" }
            }
        }
        catch {
            $errors += "Ledger event $expectedSequence could not be validated: $($_.Exception.Message)"
            break
        }
        $events += $event
        $previousSha256 = [string]$event.event_sha256
        $expectedSequence++
    }
    if ($events.Count -eq 0 -or [string]$events[0].event_type -ne 'observation_initialized' -or
        [string]$events[0].details.observation_sha256 -ne [string]$Context.observation_sha256) {
        $errors += 'Ledger does not contain a trusted initialization event bound to the observation contract.'
    }
    return [pscustomobject]@{
        events = @($events)
        integrity = if ($errors.Count -eq 0) { 'valid' } else { 'tampered' }
        errors = @($errors)
        head_sha256 = if ($events.Count -gt 0) { [string]$events[-1].event_sha256 } else { '0' * 64 }
        last_sequence = $events.Count
    }
}

function New-AgentOSObservationSnapshotFromLedger {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$TrustedLedger)

    $stageMap = [ordered]@{}
    foreach ($stage in @($Context.contract.stages)) {
        $stageMap[[string]$stage.stage_id] = [pscustomobject][ordered]@{
            stage_id = [string]$stage.stage_id
            state = 'pending'
            started_at = ''
            reservation = New-AgentOSObservationZeroMetrics
            usage = New-AgentOSObservationZeroMetrics
        }
    }
    $actual = New-AgentOSObservationZeroMetrics
    $reserved = New-AgentOSObservationZeroMetrics
    $terminalState = ''
    foreach ($event in @($TrustedLedger.events)) {
        $stageId = [string]$event.stage_id
        switch ([string]$event.event_type) {
            'stage_started' {
                $stageMap[$stageId].state = 'running'
                $stageMap[$stageId].started_at = ConvertTo-AgentOSObservationDateText -Value $event.details.started_at
                $stageMap[$stageId].reservation = $event.details.reservation
                $reserved = Add-AgentOSObservationMetrics -Left $reserved -Right $event.details.reservation
            }
            'stage_blocked_budget' {
                $stageMap[$stageId].state = 'blocked'
                $hasUsage = if ($event.details -is [Collections.IDictionary]) {
                    $event.details.Contains('usage')
                }
                else {
                    $null -ne $event.details.PSObject.Properties['usage']
                }
                if ($hasUsage) {
                    $stageMap[$stageId].usage = $event.details.usage
                    $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                    $reserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageMap[$stageId].reservation
                }
                $terminalState = 'blocked_budget'
            }
            'stage_succeeded' {
                $stageMap[$stageId].state = 'succeeded'
                $stageMap[$stageId].usage = $event.details.usage
                $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                $reserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageMap[$stageId].reservation
            }
            'stage_failed' {
                $stageMap[$stageId].state = 'failed'
                $stageMap[$stageId].usage = $event.details.usage
                $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                $reserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageMap[$stageId].reservation
                $terminalState = 'failed'
            }
            'stage_blocked_quality' {
                $stageMap[$stageId].state = 'blocked'
                $stageMap[$stageId].usage = $event.details.usage
                $actual = Add-AgentOSObservationMetrics -Left $actual -Right $event.details.usage
                $reserved = Subtract-AgentOSObservationMetrics -Left $reserved -Right $stageMap[$stageId].reservation
                $terminalState = 'blocked_quality'
            }
            'evaluation_passed' { $terminalState = 'passed' }
        }
    }
    $states = @($stageMap.Values)
    $state = if ($terminalState) { $terminalState }
        elseif (@($states | Where-Object { $_.state -eq 'running' }).Count -gt 0) { 'running' }
        elseif (@($states | Where-Object { $_.state -eq 'succeeded' }).Count -eq $states.Count) { 'ready_for_evaluation' }
        else { 'ready' }
    return [pscustomobject][ordered]@{
        schema_version = '0.1'
        observation_id = [string]$Context.contract.observation_id
        observation_sha256 = [string]$Context.observation_sha256
        state = $state
        stages = $states
        actual_totals = $actual
        reserved_totals = $reserved
        last_trusted_sequence = [int]$TrustedLedger.last_sequence
        ledger_head_sha256 = [string]$TrustedLedger.head_sha256
        updated_at = [DateTimeOffset]::Now.ToString('o')
    }
}

function Write-AgentOSObservationLedgerEvent {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Event)

    $line = (ConvertTo-AgentOSObservationJson -Value $Event) -replace "`r?`n", ''
    [IO.File]::AppendAllText($Context.ledger_path, "`n$line", [Text.UTF8Encoding]::new($false))
}

function Write-AgentOSObservationSnapshot {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Snapshot)

    $temporaryPath = Join-Path $Context.observation_path ('.snapshot-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
    Write-AgentOSObservationCreateNew -LiteralPath $temporaryPath -Text (ConvertTo-AgentOSObservationJson -Value $Snapshot)
    Move-Item -LiteralPath $temporaryPath -Destination $Context.snapshot_path -Force
}

function Invoke-WithAgentOSObservationLock {
    param([Parameter(Mandatory)][string]$ObservationPath, [Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $lockPath = Join-Path $ObservationPath '.observer.lock'
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        throw 'Agent OS observation is already being mutated.'
    }
    try { return & $ScriptBlock }
    finally { $lock.Dispose() }
}

function Start-AgentOSObservationStage {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$StageRequestPath
    )

    $requestSource = Read-AgentOSObservationBoundJson -LiteralPath $StageRequestPath -SchemaName 'agent_os_observability_stage_request.schema.json'
    $request = $requestSource.document
    $preflightContext = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    return Invoke-WithAgentOSObservationLock -ObservationPath $preflightContext.observation_path -ScriptBlock {
        $context = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
        $trusted = Get-AgentOSObservationTrustedLedger -Context $context
        if ($trusted.integrity -ne 'valid') { throw 'Agent OS observation Ledger is tampered.' }
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        if ($snapshot.state -in @('passed', 'failed', 'blocked_budget', 'blocked_quality')) {
            throw "Agent OS observation is terminal in state '$($snapshot.state)'."
        }
        if ([string]$request.observation_id -ne [string]$context.contract.observation_id) {
            throw 'Agent OS stage request is bound to another observation.'
        }
        $stageContract = @($context.contract.stages | Where-Object { [string]$_.stage_id -eq [string]$request.stage_id })
        if ($stageContract.Count -ne 1) { throw 'Agent OS stage request names an unknown stage.' }
        $stageState = @($snapshot.stages | Where-Object { [string]$_.stage_id -eq [string]$request.stage_id })[0]
        if ([string]$stageState.state -ne 'pending') { throw 'Agent OS observation stage can only start once.' }
        foreach ($dependency in @($stageContract[0].depends_on)) {
            $dependencyState = @($snapshot.stages | Where-Object { [string]$_.stage_id -eq [string]$dependency })[0]
            if ([string]$dependencyState.state -ne 'succeeded') {
                throw "Agent OS observation stage dependency '$dependency' has not succeeded."
            }
        }
        $projected = Add-AgentOSObservationMetrics -Left $snapshot.actual_totals -Right $snapshot.reserved_totals
        $projected = Add-AgentOSObservationMetrics -Left $projected -Right $request.reservation
        $exceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $projected -Budgets $context.contract.budgets)
        $eventType = if ($exceeded.Count -gt 0) { 'stage_blocked_budget' } else { 'stage_started' }
        $details = [ordered]@{
            request_sha256 = [string]$requestSource.sha256
            started_at = ConvertTo-AgentOSObservationDateText -Value $request.started_at
            reservation = $request.reservation
            exceeded_dimensions = @($exceeded)
        }
        $event = New-AgentOSObservationEvent -ObservationId ([string]$context.contract.observation_id) -Sequence ($trusted.last_sequence + 1) -EventType $eventType -PreviousSha256 $trusted.head_sha256 -Details $details -StageId ([string]$request.stage_id)
        Write-AgentOSObservationLedgerEvent -Context $context -Event $event
        $trusted.events += $event
        $trusted.last_sequence++
        $trusted.head_sha256 = [string]$event.event_sha256
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        Write-AgentOSObservationSnapshot -Context $context -Snapshot $snapshot
        return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256
    }
}

function Test-AgentOSObservationEvidenceRef {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$EvidenceRef)

    $fullPath = [IO.Path]::GetFullPath([string]$EvidenceRef.path)
    $withinApprovedRoot = $false
    foreach ($root in @($Context.contract.evidence_roots)) {
        if (Test-AgentOSObservationPathWithinRoot -Path $fullPath -Root ([string]$root)) {
            $withinApprovedRoot = $true
            break
        }
    }
    if (-not $withinApprovedRoot) {
        throw 'Agent OS observation evidence path is outside the contract roots.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw 'Agent OS observation evidence file does not exist.'
    }
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $fullPath
    if ((Get-AgentOSObservationFileSha256 -LiteralPath $fullPath) -ne [string]$EvidenceRef.sha256) {
        throw 'Agent OS observation evidence hash does not match.'
    }
    return $true
}

function Get-AgentOSObservationQualityFailures {
    param(
        [Parameter(Mandatory)]$StageContract,
        [Parameter(Mandatory)]$Measurements,
        [Parameter(Mandatory)]$Context
    )

    $failures = @()
    $measurementById = @{}
    foreach ($measurement in @($Measurements)) {
        $gateId = [string]$measurement.gate_id
        if ($measurementById.ContainsKey($gateId)) {
            $failures += "duplicate_measurement:$gateId"
            continue
        }
        $measurementById[$gateId] = $measurement
    }
    $gateIds = @($StageContract.quality_gates | ForEach-Object { [string]$_.gate_id })
    foreach ($extraId in @($measurementById.Keys | Where-Object { $_ -notin $gateIds } | Sort-Object)) {
        $failures += "undeclared_measurement:$extraId"
    }
    foreach ($gate in @($StageContract.quality_gates)) {
        $gateId = [string]$gate.gate_id
        if (-not $measurementById.ContainsKey($gateId)) {
            $failures += "missing_measurement:$gateId"
            continue
        }
        $measurement = $measurementById[$gateId]
        if ([string]$measurement.metric -ne [string]$gate.metric -or [string]$measurement.unit -ne [string]$gate.unit) {
            $failures += "measurement_identity_mismatch:$gateId"
            continue
        }
        if ([bool]$gate.evidence_required -and @($measurement.evidence).Count -eq 0) {
            $failures += "missing_evidence:$gateId"
        }
        foreach ($evidenceRef in @($measurement.evidence)) {
            [void](Test-AgentOSObservationEvidenceRef -Context $Context -EvidenceRef $evidenceRef)
        }
        $value = [int64]$measurement.value
        $threshold = [int64]$gate.threshold
        $passed = switch ([string]$gate.operator) {
            'gte' { $value -ge $threshold }
            'lte' { $value -le $threshold }
            'eq' { $value -eq $threshold }
            default { $false }
        }
        if (-not $passed) { $failures += "threshold_failed:$gateId" }
    }
    return @($failures)
}

function Assert-AgentOSObservationAcceptedResultEvidence {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Details)

    if ([int64]$Details.usage.cost_microunits -gt 0 -and @($Details.cost_evidence).Count -eq 0) {
        throw 'non-zero cost event lacks contract-bound evidence'
    }
    foreach ($evidenceRef in @($Details.cost_evidence)) {
        [void](Test-AgentOSObservationEvidenceRef -Context $Context -EvidenceRef $evidenceRef)
    }
    foreach ($measurement in @($Details.quality_measurements)) {
        foreach ($evidenceRef in @($measurement.evidence)) {
            [void](Test-AgentOSObservationEvidenceRef -Context $Context -EvidenceRef $evidenceRef)
        }
    }
}

function Get-AgentOSObservationRecalculatedQualityFailures {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$StageContract,
        [Parameter(Mandatory)]$Details
    )

    if (@($Details.failure_reasons).Count -gt 0) { return @() }
    return @(Get-AgentOSObservationQualityFailures -StageContract $StageContract -Measurements $Details.quality_measurements -Context $Context)
}

function Finish-AgentOSObservationStage {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$StageResultPath
    )

    $resultSource = Read-AgentOSObservationBoundJson -LiteralPath $StageResultPath -SchemaName 'agent_os_observability_stage_result.schema.json'
    $result = $resultSource.document
    $preflightContext = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    return Invoke-WithAgentOSObservationLock -ObservationPath $preflightContext.observation_path -ScriptBlock {
        $context = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
        $trusted = Get-AgentOSObservationTrustedLedger -Context $context
        if ($trusted.integrity -ne 'valid') { throw 'Agent OS observation Ledger is tampered.' }
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        if ($snapshot.state -in @('passed', 'failed', 'blocked_budget', 'blocked_quality')) {
            throw "Agent OS observation is terminal in state '$($snapshot.state)'."
        }
        if ([string]$result.observation_id -ne [string]$context.contract.observation_id) {
            throw 'Agent OS stage result is bound to another observation.'
        }
        $stageContract = @($context.contract.stages | Where-Object { [string]$_.stage_id -eq [string]$result.stage_id })
        if ($stageContract.Count -ne 1) { throw 'Agent OS stage result names an unknown stage.' }
        $stageState = @($snapshot.stages | Where-Object { [string]$_.stage_id -eq [string]$result.stage_id })[0]
        if ([string]$stageState.state -ne 'running') { throw 'Agent OS observation stage is not running.' }

        $startedAt = [DateTimeOffset]::Parse([string]$stageState.started_at)
        $finishedAt = [DateTimeOffset]::Parse([string]$result.finished_at)
        $elapsedMs = [int64][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
        if ($elapsedMs -lt 0 -or $elapsedMs -ne [int64]$result.usage.duration_ms) {
            throw 'Agent OS observation duration does not match the stage timestamps.'
        }
        if ([int64]$result.usage.cost_microunits -gt 0 -and @($result.cost_evidence).Count -eq 0) {
            throw 'Agent OS observation non-zero cost requires cost evidence.'
        }
        foreach ($evidenceRef in @($result.cost_evidence)) {
            [void](Test-AgentOSObservationEvidenceRef -Context $context -EvidenceRef $evidenceRef)
        }
        foreach ($measurement in @($result.quality_measurements)) {
            foreach ($evidenceRef in @($measurement.evidence)) {
                [void](Test-AgentOSObservationEvidenceRef -Context $context -EvidenceRef $evidenceRef)
            }
        }

        $otherReserved = Subtract-AgentOSObservationMetrics -Left $snapshot.reserved_totals -Right $stageState.reservation
        $projectedActual = Add-AgentOSObservationMetrics -Left $snapshot.actual_totals -Right $otherReserved
        $projectedActual = Add-AgentOSObservationMetrics -Left $projectedActual -Right $result.usage
        $exceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $projectedActual -Budgets $context.contract.budgets)
        $qualityFailures = @()
        if ([string]$result.status -eq 'succeeded') {
            $qualityFailures = @(Get-AgentOSObservationQualityFailures -StageContract $stageContract[0] -Measurements $result.quality_measurements -Context $context)
        }
        $eventType = if ($exceeded.Count -gt 0) { 'stage_blocked_budget' }
            elseif ([string]$result.status -eq 'failed') { 'stage_failed' }
            elseif ($qualityFailures.Count -gt 0) { 'stage_blocked_quality' }
            else { 'stage_succeeded' }
        $details = [ordered]@{
            result_sha256 = [string]$resultSource.sha256
            finished_at = ConvertTo-AgentOSObservationDateText -Value $result.finished_at
            usage = $result.usage
            quality_measurements = @($result.quality_measurements)
            cost_evidence = @($result.cost_evidence)
            failure_reasons = @($result.failure_reasons)
            exceeded_dimensions = @($exceeded)
            quality_failures = @($qualityFailures)
        }
        $event = New-AgentOSObservationEvent -ObservationId ([string]$context.contract.observation_id) -Sequence ($trusted.last_sequence + 1) -EventType $eventType -PreviousSha256 $trusted.head_sha256 -Details $details -StageId ([string]$result.stage_id)
        Write-AgentOSObservationLedgerEvent -Context $context -Event $event
        $trusted.events += $event
        $trusted.last_sequence++
        $trusted.head_sha256 = [string]$event.event_sha256
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        Write-AgentOSObservationSnapshot -Context $context -Snapshot $snapshot
        return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256
    }
}

function Invoke-AgentOSObservationEvaluation {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $preflightContext = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    return Invoke-WithAgentOSObservationLock -ObservationPath $preflightContext.observation_path -ScriptBlock {
        $context = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
        $trusted = Get-AgentOSObservationTrustedLedger -Context $context
        if ($trusted.integrity -ne 'valid') { throw 'Agent OS observation Ledger is tampered.' }
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        if ($snapshot.state -eq 'passed') {
            return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256
        }
        if ($snapshot.state -ne 'ready_for_evaluation') {
            throw "Agent OS observation is not ready for evaluation: $($snapshot.state)."
        }
        $exceeded = @(Get-AgentOSObservationExceededBudgets -Metrics $snapshot.actual_totals -Budgets $context.contract.budgets)
        if ($exceeded.Count -gt 0) {
            throw 'Agent OS observation cannot pass with an exceeded budget.'
        }
        foreach ($stageContract in @($context.contract.stages)) {
            $stageId = [string]$stageContract.stage_id
            $stageEvent = @($trusted.events | Where-Object { [string]$_.event_type -eq 'stage_succeeded' -and [string]$_.stage_id -eq $stageId })
            if ($stageEvent.Count -ne 1) {
                throw "Agent OS observation stage '$stageId' does not have exactly one trusted success event."
            }
            foreach ($evidenceRef in @($stageEvent[0].details.cost_evidence)) {
                [void](Test-AgentOSObservationEvidenceRef -Context $context -EvidenceRef $evidenceRef)
            }
            $qualityFailures = @(Get-AgentOSObservationQualityFailures -StageContract $stageContract -Measurements $stageEvent[0].details.quality_measurements -Context $context)
            if ($qualityFailures.Count -gt 0) {
                throw "Agent OS observation stage '$stageId' no longer passes its quality gates."
            }
        }
        $event = New-AgentOSObservationEvent -ObservationId ([string]$context.contract.observation_id) -Sequence ($trusted.last_sequence + 1) -EventType 'evaluation_passed' -PreviousSha256 $trusted.head_sha256 -Details ([ordered]@{ actual_totals = $snapshot.actual_totals; stage_count = @($snapshot.stages).Count })
        Write-AgentOSObservationLedgerEvent -Context $context -Event $event
        $trusted.events += $event
        $trusted.last_sequence++
        $trusted.head_sha256 = [string]$event.event_sha256
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        Write-AgentOSObservationSnapshot -Context $context -Snapshot $snapshot
        return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256
    }
}

function Get-AgentOSObservationInspection {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $context = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    $trusted = Get-AgentOSObservationTrustedLedger -Context $context
    $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
    return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256 -LedgerIntegrity $trusted.integrity -LedgerErrors $trusted.errors
}

function Test-AgentOSObservationSnapshotCurrent {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$ExpectedSnapshot)

    if (-not (Test-Path -LiteralPath $Context.snapshot_path -PathType Leaf)) { return $false }
    try {
        $snapshot = Read-AgentOSObservationJson -LiteralPath $Context.snapshot_path
    }
    catch { return $false }
    $names = @('schema_version', 'observation_id', 'observation_sha256', 'state', 'stages', 'actual_totals', 'reserved_totals', 'last_trusted_sequence', 'ledger_head_sha256')
    $actualComparable = [ordered]@{}
    $expectedComparable = [ordered]@{}
    foreach ($name in $names) {
        if (-not $snapshot.PSObject.Properties[$name] -or -not $ExpectedSnapshot.PSObject.Properties[$name]) { return $false }
        $actualComparable[$name] = ConvertTo-AgentOSObservationStableHashValue -Value $snapshot.$name
        $expectedComparable[$name] = ConvertTo-AgentOSObservationStableHashValue -Value $ExpectedSnapshot.$name
    }
    return (ConvertTo-AgentOSObservationJson -Value $actualComparable) -eq (ConvertTo-AgentOSObservationJson -Value $expectedComparable)
}

function Recover-AgentOSObservation {
    param(
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $preflightContext = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    return Invoke-WithAgentOSObservationLock -ObservationPath $preflightContext.observation_path -ScriptBlock {
        $context = Get-AgentOSObservationContext -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
        $trusted = Get-AgentOSObservationTrustedLedger -Context $context
        $snapshot = New-AgentOSObservationSnapshotFromLedger -Context $context -TrustedLedger $trusted
        if ($trusted.integrity -ne 'valid') {
            return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256 -LedgerIntegrity $trusted.integrity -LedgerErrors $trusted.errors
        }
        $rewritten = -not (Test-AgentOSObservationSnapshotCurrent -Context $context -ExpectedSnapshot $snapshot)
        if ($rewritten) {
            Write-AgentOSObservationSnapshot -Context $context -Snapshot $snapshot
        }
        return New-AgentOSObservationResult -ObservationPath $context.observation_path -Contract $context.contract -Snapshot $snapshot -ObservationSha256 $context.observation_sha256 -SnapshotRewritten $rewritten
    }
}

function Initialize-AgentOSObservation {
    param(
        [Parameter(Mandatory)][string]$ObservationSpecPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $specSource = Read-AgentOSObservationBoundJson -LiteralPath $ObservationSpecPath -SchemaName 'agent_os_observability_spec.schema.json'
    $spec = $specSource.document
    Assert-AgentOSObservationStageGraph -Stages $spec.stages

    $subjectContractPath = [IO.Path]::GetFullPath([string]$spec.subject.contract_path)
    if (-not (Test-Path -LiteralPath $subjectContractPath -PathType Leaf)) {
        throw 'Agent OS observation subject contract does not exist.'
    }
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $subjectContractPath
    $subjectSource = Read-AgentOSObservationSubjectContract `
        -LiteralPath $subjectContractPath `
        -Kind ([string]$spec.subject.kind) `
        -SubjectId ([string]$spec.subject.subject_id)
    if ([string]$subjectSource.sha256 -ne [string]$spec.subject.contract_sha256) {
        throw 'Agent OS observation subject contract hash does not match the specification.'
    }
    $subjectRoot = Split-Path -Parent $subjectContractPath
    $evidenceRoots = @()
    foreach ($root in @($spec.evidence_roots)) {
        $fullRoot = [IO.Path]::GetFullPath([string]$root)
        if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
            throw "Agent OS observation evidence root does not exist: $fullRoot"
        }
        if (-not (Test-AgentOSObservationPathWithinRoot -Path $fullRoot -Root $subjectRoot)) {
            throw 'Agent OS observation evidence roots must stay within the subject contract directory.'
        }
        Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $fullRoot
        $evidenceRoots += $fullRoot
    }

    $fullRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    Assert-AgentOSObservationExistingAncestorsAreNotReparsePoints -LiteralPath $fullRuntimeRoot
    New-Item -ItemType Directory -Path $fullRuntimeRoot -Force -ErrorAction Stop | Out-Null
    Assert-AgentOSObservationItemIsNotReparsePoint -LiteralPath $fullRuntimeRoot

    $observationId = 'agent-os-observation-{0}-{1}' -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $observationPath = Join-Path $fullRuntimeRoot $observationId
    New-Item -ItemType Directory -Path $observationPath -ErrorAction Stop | Out-Null
    Write-AgentOSObservationCreateNew -LiteralPath (Join-Path $observationPath '.observer.lock') -Text 'observer-lock-v1'

    $contract = [pscustomobject][ordered]@{
        schema_version = '0.1'
        observation_id = $observationId
        observation_key = [string]$spec.observation_key
        created_at = [DateTimeOffset]::Now.ToString('o')
        source_spec_sha256 = [string]$specSource.sha256
        subject = [pscustomobject][ordered]@{
            kind = [string]$spec.subject.kind
            subject_id = [string]$spec.subject.subject_id
            contract_path = $subjectContractPath
            contract_sha256 = [string]$spec.subject.contract_sha256
        }
        evidence_roots = @($evidenceRoots)
        budgets = $spec.budgets
        stages = @($spec.stages)
    }
    $contractPath = Join-Path $observationPath 'observation.json'
    Write-AgentOSObservationCreateNew -LiteralPath $contractPath -Text (ConvertTo-AgentOSObservationJson -Value $contract)
    $contractSource = Read-AgentOSObservationBoundJson -LiteralPath $contractPath -SchemaName 'agent_os_observability_contract.schema.json'
    $contractSha256 = [string]$contractSource.sha256

    $event = New-AgentOSObservationEvent -ObservationId $observationId -Sequence 1 -EventType 'observation_initialized' -PreviousSha256 ('0' * 64) -Details ([ordered]@{ observation_sha256 = $contractSha256 })
    Write-AgentOSObservationCreateNew -LiteralPath (Join-Path $observationPath 'ledger.jsonl') -Text ((ConvertTo-AgentOSObservationJson -Value $event) -replace "`r?`n", '')

    $stageStates = @($contract.stages | ForEach-Object {
        [pscustomobject][ordered]@{
            stage_id = [string]$_.stage_id
            state = 'pending'
            started_at = ''
            reservation = New-AgentOSObservationZeroMetrics
            usage = New-AgentOSObservationZeroMetrics
        }
    })
    $snapshot = [pscustomobject][ordered]@{
        schema_version = '0.1'
        observation_id = $observationId
        observation_sha256 = $contractSha256
        state = 'ready'
        stages = $stageStates
        actual_totals = New-AgentOSObservationZeroMetrics
        reserved_totals = New-AgentOSObservationZeroMetrics
        last_trusted_sequence = 1
        ledger_head_sha256 = [string]$event.event_sha256
        updated_at = [DateTimeOffset]::Now.ToString('o')
    }
    Write-AgentOSObservationCreateNew -LiteralPath (Join-Path $observationPath 'snapshot.json') -Text (ConvertTo-AgentOSObservationJson -Value $snapshot)
    return New-AgentOSObservationResult -ObservationPath $observationPath -Contract $contract -Snapshot $snapshot -ObservationSha256 $contractSha256
}

function Invoke-AgentOSObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Initialize', 'StartStage', 'FinishStage', 'Evaluate', 'Inspect', 'Recover')]
        [string]$Action,
        [string]$ObservationSpecPath,
        [string]$RuntimeRoot,
        [string]$ObservationPath,
        [string]$StageRequestPath,
        [string]$StageResultPath
    )

    if ($Action -eq 'Initialize') {
        if (-not $ObservationSpecPath) { throw 'ObservationSpecPath is required for Initialize.' }
        return Initialize-AgentOSObservation -ObservationSpecPath $ObservationSpecPath -RuntimeRoot $RuntimeRoot
    }
    if ($Action -eq 'StartStage') {
        if (-not $ObservationPath -or -not $StageRequestPath) { throw 'ObservationPath and StageRequestPath are required for StartStage.' }
        return Start-AgentOSObservationStage -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot -StageRequestPath $StageRequestPath
    }
    if ($Action -eq 'FinishStage') {
        if (-not $ObservationPath -or -not $StageResultPath) { throw 'ObservationPath and StageResultPath are required for FinishStage.' }
        return Finish-AgentOSObservationStage -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot -StageResultPath $StageResultPath
    }
    if ($Action -eq 'Evaluate') {
        if (-not $ObservationPath) { throw 'ObservationPath is required for Evaluate.' }
        return Invoke-AgentOSObservationEvaluation -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    }
    if ($Action -eq 'Inspect') {
        if (-not $ObservationPath) { throw 'ObservationPath is required for Inspect.' }
        return Get-AgentOSObservationInspection -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    }
    if ($Action -eq 'Recover') {
        if (-not $ObservationPath) { throw 'ObservationPath is required for Recover.' }
        return Recover-AgentOSObservation -ObservationPath $ObservationPath -RuntimeRoot $RuntimeRoot
    }
    throw "Agent OS observation action '$Action' is not implemented yet."
}

Export-ModuleMember -Function 'Invoke-AgentOSObservation'
