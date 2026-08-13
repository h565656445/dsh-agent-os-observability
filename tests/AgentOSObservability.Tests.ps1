$ErrorActionPreference = 'Stop'

# Pester 5 兼容化：初始化与辅助函数移入 BeforeAll（Discovery/Run 作用域隔离），
# 候选验证经 HERMES_HARNESS_ROOT 注入真实项目根；晋级后 $PSScriptRoot 兜底，行为等价。
BeforeAll {

    $script:HarnessRoot = $env:HERMES_HARNESS_ROOT
    if (-not $script:HarnessRoot) {
        $script:HarnessRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = $script:HarnessRoot
$observerRunnerPath = Join-Path $projectRoot 'runner\agent_os_observability.ps1'
$observerContractSchemaPath = Join-Path $projectRoot 'schemas\agent_os_observability_contract.schema.json'

function ConvertTo-TestObservationStableHashValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $mapped = [ordered]@{}
        foreach ($key in $Value.Keys) { $mapped[[string]$key] = ConvertTo-TestObservationStableHashValue $Value[$key] }
        return $mapped
    }
    if ($Value -is [pscustomobject]) {
        $mapped = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $mapped[$property.Name] = ConvertTo-TestObservationStableHashValue $property.Value }
        return $mapped
    }
    if ($Value -is [Collections.IEnumerable]) { return @($Value | ForEach-Object { ConvertTo-TestObservationStableHashValue $_ }) }
    return $Value
}

function Get-TestObservationEventHash {
    param([Parameter(Mandatory)]$Event)

    $hashInput = [ordered]@{}
    foreach ($property in $Event.PSObject.Properties) {
        if ($property.Name -ne 'event_sha256') { $hashInput[$property.Name] = ConvertTo-TestObservationStableHashValue $property.Value }
    }
    $json = ($hashInput | ConvertTo-Json -Depth 50) -replace "`r`n", "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function New-TestObservationSpec {
    param(
        [Parameter(Mandatory)][string]$Root,
        [object[]]$Stages,
        [hashtable]$Budgets
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $subjectRoot = Join-Path $Root 'subject'
    $evidenceRoot = Join-Path $subjectRoot 'evidence'
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $subjectContractPath = Join-Path $subjectRoot 'contract.json'
    $subjectId = 'agent-os-graph-20260718-010000-aaaaaaaa'
    [ordered]@{
        schema_version = '0.1'
        graph_id = $subjectId
        graph_key = 'subject-a'
        created_at = '2026-07-18T01:00:00+09:00'
        source_spec_sha256 = '0' * 64
        policy = [ordered]@{ max_concurrency = 1; lease_seconds = 300; pause_on_failure = $true }
        nodes = @([ordered]@{
            node_id = 'observe'
            depends_on = @()
            work_refs = @([ordered]@{ kind = 'worker_input'; path = 'placeholder.json'; sha256 = '0' * 64 })
            effect = 'read_only'
            idempotency_key = 'subject-a-observe'
            max_attempts = 1
        })
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $subjectContractPath -Encoding utf8

    if (-not $Budgets) {
        $Budgets = @{
            currency = 'USD'
            duration_ms = 60000
            model_calls = 2
            input_tokens = 1000
            output_tokens = 500
            cost_microunits = 1000000
        }
    }
    if (-not $Stages) {
        $Stages = @(
            [ordered]@{
                stage_id = 'prepare'
                depends_on = @()
                quality_gates = @(
                    [ordered]@{
                        gate_id = 'schema-valid'
                        metric = 'schema_score'
                        unit = 'percent'
                        operator = 'gte'
                        threshold = 100
                        evidence_required = $true
                    }
                )
            },
            [ordered]@{
                stage_id = 'verify'
                depends_on = @('prepare')
                quality_gates = @()
            }
        )
    }

    $specPath = Join-Path $Root 'observation-spec.json'
    [ordered]@{
        schema_version = '0.1'
        observation_key = 'test-observation'
        subject = [ordered]@{
            kind = 'graph'
            subject_id = $subjectId
            contract_path = $subjectContractPath
            contract_sha256 = (Get-FileHash -LiteralPath $subjectContractPath -Algorithm SHA256).Hash
        }
        evidence_roots = @($evidenceRoot)
        budgets = $Budgets
        stages = $Stages
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $specPath -Encoding utf8
    return [pscustomobject]@{
        spec_path = $specPath
        subject_contract_path = $subjectContractPath
        evidence_root = $evidenceRoot
    }
}

function Write-TestStageRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)][string]$StageId,
        [string]$StartedAt = '2026-07-18T01:00:00+09:00',
        [int64]$DurationMs = 1000,
        [int64]$ModelCalls = 1,
        [int64]$InputTokens = 100,
        [int64]$OutputTokens = 50,
        [int64]$CostMicrounits = 100000
    )

    [ordered]@{
        schema_version = '0.1'
        observation_id = $Observation.observation_id
        stage_id = $StageId
        started_at = $StartedAt
        reservation = [ordered]@{
            duration_ms = $DurationMs
            model_calls = $ModelCalls
            input_tokens = $InputTokens
            output_tokens = $OutputTokens
            cost_microunits = $CostMicrounits
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}

function Write-TestStageResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)][string]$StageId,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$FinishedAt = '2026-07-18T01:00:01+09:00',
        [ValidateSet('succeeded', 'failed')][string]$Status = 'succeeded',
        [int64]$DurationMs = 1000,
        [int64]$ModelCalls = 1,
        [int64]$InputTokens = 100,
        [int64]$OutputTokens = 50,
        [int64]$CostMicrounits = 100000,
        [int64]$QualityValue = 100,
        [switch]$WithoutQuality
    )

    $evidencePath = Join-Path $EvidenceRoot "$StageId-evidence.txt"
    "verified evidence for $StageId" | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $evidence = @([ordered]@{ path = $evidencePath; sha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash })
    $measurements = @()
    if (-not $WithoutQuality -and $StageId -eq 'prepare') {
        $measurements = @(
            [ordered]@{
                gate_id = 'schema-valid'
                metric = 'schema_score'
                unit = 'percent'
                value = $QualityValue
                evidence = $evidence
            }
        )
    }
    $failureReasons = @()
    if ($Status -eq 'failed') { $failureReasons = @('fixture stage failure') }
    $costEvidence = [Collections.Generic.List[object]]::new()
    if ($CostMicrounits -gt 0) { $costEvidence.Add($evidence[0]) }
    [ordered]@{
        schema_version = '0.1'
        observation_id = $Observation.observation_id
        stage_id = $StageId
        finished_at = $FinishedAt
        status = $Status
        usage = [ordered]@{
            duration_ms = $DurationMs
            model_calls = $ModelCalls
            input_tokens = $InputTokens
            output_tokens = $OutputTokens
            cost_microunits = $CostMicrounits
        }
        quality_measurements = $measurements
        cost_evidence = $costEvidence
        failure_reasons = $failureReasons
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}

}

Describe 'Agent OS observability, cost, and quality public interface' {
    It 'initializes an immutable observation with ledger and snapshot anchors' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'initialize')
        $runtimeRoot = Join-Path $TestDrive 'runtime'

        $observation = & $observerRunnerPath `
            -Action Initialize `
            -ObservationSpecPath $fixture.spec_path `
            -RuntimeRoot $runtimeRoot `
            -AsJson | ConvertFrom-Json -Depth 50

        $observation.state | Should -Be 'ready'
        $observation.ledger_integrity | Should -Be 'valid'
        $observation.last_trusted_sequence | Should -Be 1
        $observation.stage_counts.pending | Should -Be 2
        $observation.actual_totals.cost_microunits | Should -Be 0
        $observation.reserved_totals.input_tokens | Should -Be 0
        $observation.observation_sha256 | Should -Match '^[A-F0-9]{64}$'
        Test-Path -LiteralPath $observation.observation_path | Should -Be $true
        Test-Path -LiteralPath $observation.ledger_path | Should -Be $true
        Test-Path -LiteralPath $observation.snapshot_path | Should -Be $true
        (Get-Content -LiteralPath $observation.contract_path -Raw |
            Test-Json -SchemaFile $observerContractSchemaPath) | Should -Be $true
    }

    It 'starts only a dependency-ready stage and records its reserved metrics' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'start-stage')
        $runtimeRoot = Join-Path $TestDrive 'runtime-start'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'start-prepare.json') -Observation $observation -StageId 'prepare'

        $started = & $observerRunnerPath `
            -Action StartStage `
            -ObservationPath $observation.observation_path `
            -RuntimeRoot $runtimeRoot `
            -StageRequestPath $requestPath `
            -AsJson | ConvertFrom-Json -Depth 50

        $started.state | Should -Be 'running'
        $started.stage_counts.running | Should -Be 1
        $started.stage_counts.pending | Should -Be 1
        $started.reserved_totals.duration_ms | Should -Be 1000
        $started.reserved_totals.input_tokens | Should -Be 100
        $started.actual_totals.input_tokens | Should -Be 0
        $started.last_trusted_sequence | Should -Be 2
        $started.ledger_integrity | Should -Be 'valid'
        $startEvent = (Get-Content -LiteralPath $started.ledger_path)[1] | ConvertFrom-Json -Depth 50
        $startEvent.details.request_sha256 | Should -Be (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash
    }

    It 'finishes a quality-passing stage and unlocks its dependent stage' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'finish-stage')
        $runtimeRoot = Join-Path $TestDrive 'runtime-finish'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'finish-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'finish-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root

        $finished = & $observerRunnerPath `
            -Action FinishStage `
            -ObservationPath $observation.observation_path `
            -RuntimeRoot $runtimeRoot `
            -StageResultPath $resultPath `
            -AsJson | ConvertFrom-Json -Depth 50

        $finished.state | Should -Be 'ready'
        $finished.stage_counts.succeeded | Should -Be 1
        $finished.stage_counts.pending | Should -Be 1
        $finished.stage_counts.running | Should -Be 0
        $finished.actual_totals.duration_ms | Should -Be 1000
        $finished.actual_totals.cost_microunits | Should -Be 100000
        $finished.reserved_totals.cost_microunits | Should -Be 0
        $finished.last_trusted_sequence | Should -Be 3

        $verifyRequest = Write-TestStageRequest -Path (Join-Path $TestDrive 'verify-start.json') -Observation $observation -StageId 'verify' -StartedAt '2026-07-18T01:00:02+09:00' -ModelCalls 0 -InputTokens 0 -OutputTokens 0 -CostMicrounits 0
        $verifyStarted = & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $verifyRequest -AsJson |
            ConvertFrom-Json -Depth 50
        $verifyStarted.state | Should -Be 'running'
        $verifyStarted.stage_counts.running | Should -Be 1
    }

    It 'fails closed before a stage starts when its reservation exceeds budget' {
        $budgets = @{
            currency = 'USD'; duration_ms = 500; model_calls = 0; input_tokens = 10
            output_tokens = 10; cost_microunits = 10
        }
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'start-budget') -Budgets $budgets
        $runtimeRoot = Join-Path $TestDrive 'runtime-start-budget'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'over-budget-start.json') -Observation $observation -StageId 'prepare'

        $blocked = & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson |
            ConvertFrom-Json -Depth 50

        $blocked.state | Should -Be 'blocked_budget'
        $blocked.stage_counts.blocked | Should -Be 1
        $blocked.actual_totals.cost_microunits | Should -Be 0
        $blocked.reserved_totals.cost_microunits | Should -Be 0
        $blocked.last_trusted_sequence | Should -Be 2
        $threw = $false
        try { & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
    }

    It 'fails closed when a valid stage result exceeds the actual budget' {
        $budgets = @{
            currency = 'USD'; duration_ms = 60000; model_calls = 2; input_tokens = 1000
            output_tokens = 500; cost_microunits = 150000
        }
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'actual-budget') -Budgets $budgets
        $runtimeRoot = Join-Path $TestDrive 'runtime-actual-budget'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'actual-budget-start.json') -Observation $observation -StageId 'prepare' -CostMicrounits 100000
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'actual-budget-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root -CostMicrounits 200000

        $blocked = & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson |
            ConvertFrom-Json -Depth 50

        $blocked.state | Should -Be 'blocked_budget'
        $blocked.stage_counts.blocked | Should -Be 1
        $blocked.actual_totals.cost_microunits | Should -Be 200000
        $blocked.reserved_totals.cost_microunits | Should -Be 0
        $blocked.last_trusted_sequence | Should -Be 3
    }

    It 'fails closed when a declared quality threshold is not met' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'quality-fail')
        $runtimeRoot = Join-Path $TestDrive 'runtime-quality-fail'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'quality-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'quality-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root -QualityValue 99

        $blocked = & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson |
            ConvertFrom-Json -Depth 50

        $blocked.state | Should -Be 'blocked_quality'
        $blocked.stage_counts.blocked | Should -Be 1
        $blocked.actual_totals.input_tokens | Should -Be 100
        $blocked.reserved_totals.input_tokens | Should -Be 0
        $blocked.last_trusted_sequence | Should -Be 3
    }

    It 'rejects a dependent stage before its dependency succeeds without mutating Ledger' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'dependency-block')
        $runtimeRoot = Join-Path $TestDrive 'runtime-dependency-block'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'dependency-start.json') -Observation $observation -StageId 'verify'

        $threw = $false
        try { & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 1
    }

    It 'evaluates all declared stages from Ledger and records a passing terminal event' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'evaluate-pass')
        $runtimeRoot = Join-Path $TestDrive 'runtime-evaluate-pass'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $prepareStart = Write-TestStageRequest -Path (Join-Path $TestDrive 'evaluate-prepare-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $prepareStart -AsJson | Out-Null
        $prepareResult = Write-TestStageResult -Path (Join-Path $TestDrive 'evaluate-prepare-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $prepareResult -AsJson | Out-Null

        $verifyStart = Write-TestStageRequest -Path (Join-Path $TestDrive 'evaluate-verify-start.json') -Observation $observation -StageId 'verify' -StartedAt '2026-07-18T01:00:02+09:00' -ModelCalls 0 -InputTokens 0 -OutputTokens 0 -CostMicrounits 0
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $verifyStart -AsJson | Out-Null
        $verifyResult = Write-TestStageResult -Path (Join-Path $TestDrive 'evaluate-verify-result.json') -Observation $observation -StageId 'verify' -EvidenceRoot $fixture.evidence_root -FinishedAt '2026-07-18T01:00:03+09:00' -ModelCalls 0 -InputTokens 0 -OutputTokens 0 -CostMicrounits 0 -WithoutQuality
        $ready = & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $verifyResult -AsJson |
            ConvertFrom-Json -Depth 50
        $ready.state | Should -Be 'ready_for_evaluation'

        $passed = & $observerRunnerPath -Action Evaluate -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $passed.state | Should -Be 'passed'
        $passed.stage_counts.succeeded | Should -Be 2
        $passed.actual_totals.duration_ms | Should -Be 2000
        $passed.actual_totals.model_calls | Should -Be 1
        $passed.last_trusted_sequence | Should -Be 6
        $passed.ledger_integrity | Should -Be 'valid'
    }

    It 'rebuilds a missing snapshot from the trusted Ledger' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'recover-snapshot')
        $runtimeRoot = Join-Path $TestDrive 'runtime-recover-snapshot'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'recover-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        Remove-Item -LiteralPath $observation.snapshot_path -Force

        $recovered = & $observerRunnerPath -Action Recover -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $recovered.state | Should -Be 'running'
        $recovered.ledger_integrity | Should -Be 'valid'
        $recovered.last_trusted_sequence | Should -Be 2
        $recovered.snapshot_rewritten | Should -Be $true
        Test-Path -LiteralPath $observation.snapshot_path | Should -Be $true
    }

    It 'exposes only the trusted prefix and never rewrites state when Ledger is tampered' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'tampered-ledger')
        $runtimeRoot = Join-Path $TestDrive 'runtime-tampered-ledger'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'tampered-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $lines = @(Get-Content -LiteralPath $observation.ledger_path)
        $second = $lines[1] | ConvertFrom-Json -Depth 50
        $second.details.reservation.input_tokens = 999
        $lines[1] = $second | ConvertTo-Json -Depth 50 -Compress
        $lines | Set-Content -LiteralPath $observation.ledger_path -Encoding utf8
        $snapshotHashBefore = (Get-FileHash -LiteralPath $observation.snapshot_path -Algorithm SHA256).Hash

        $inspection = & $observerRunnerPath -Action Inspect -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $inspection.ledger_integrity | Should -Be 'tampered'
        $inspection.state | Should -Be 'ready'
        $inspection.last_trusted_sequence | Should -Be 1
        $inspection.snapshot_rewritten | Should -Be $false
        $inspection.ledger_errors.Count | Should -BeGreaterThan 0
        (Get-FileHash -LiteralPath $observation.snapshot_path -Algorithm SHA256).Hash | Should -Be $snapshotHashBefore
    }

    It 'returns a trusted prefix for a hash-consistent non-integer sequence value' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'malformed-sequence')
        $runtimeRoot = Join-Path $TestDrive 'runtime-malformed-sequence'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'malformed-sequence-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $lines = @(Get-Content -LiteralPath $observation.ledger_path)
        $second = $lines[1] | ConvertFrom-Json -Depth 50
        $second.sequence = 2.1
        $second.event_sha256 = Get-TestObservationEventHash -Event $second
        $lines[1] = $second | ConvertTo-Json -Depth 50 -Compress
        $lines | Set-Content -LiteralPath $observation.ledger_path -Encoding utf8

        $inspection = & $observerRunnerPath -Action Inspect -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $inspection.ledger_integrity | Should -Be 'tampered'
        $inspection.last_trusted_sequence | Should -Be 1
        $inspection.state | Should -Be 'ready'
    }

    It 'rejects a hash-consistent terminal event with malformed result details' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'malformed-result-event')
        $runtimeRoot = Join-Path $TestDrive 'runtime-malformed-result-event'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'malformed-result-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'malformed-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson | Out-Null
        $lines = @(Get-Content -LiteralPath $observation.ledger_path)
        $third = $lines[2] | ConvertFrom-Json -Depth 50
        $third.details.result_sha256 = 'BAD'
        $third.event_sha256 = Get-TestObservationEventHash -Event $third
        $lines[2] = $third | ConvertTo-Json -Depth 50 -Compress
        $lines | Set-Content -LiteralPath $observation.ledger_path -Encoding utf8

        $inspection = & $observerRunnerPath -Action Inspect -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $inspection.ledger_integrity | Should -Be 'tampered'
        $inspection.last_trusted_sequence | Should -Be 2
        $inspection.state | Should -Be 'running'
    }

    It 'rejects a hash-consistent success event that exceeds the contract budget' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'forged-success-budget')
        $runtimeRoot = Join-Path $TestDrive 'runtime-forged-success-budget'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'forged-budget-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'forged-budget-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson | Out-Null
        $lines = @(Get-Content -LiteralPath $observation.ledger_path)
        $third = $lines[2] | ConvertFrom-Json -Depth 50
        $third.details.usage.input_tokens = 2000
        $third.event_sha256 = Get-TestObservationEventHash -Event $third
        $lines[2] = $third | ConvertTo-Json -Depth 50 -Compress
        $lines | Set-Content -LiteralPath $observation.ledger_path -Encoding utf8

        $inspection = & $observerRunnerPath -Action Inspect -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $inspection.ledger_integrity | Should -Be 'tampered'
        $inspection.last_trusted_sequence | Should -Be 2
    }

    It 'rejects a hash-consistent success event that fails its contract quality gate' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'forged-success-quality')
        $runtimeRoot = Join-Path $TestDrive 'runtime-forged-success-quality'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'forged-quality-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'forged-quality-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson | Out-Null
        $lines = @(Get-Content -LiteralPath $observation.ledger_path)
        $third = $lines[2] | ConvertFrom-Json -Depth 50
        $third.details.quality_measurements[0].value = 99
        $third.event_sha256 = Get-TestObservationEventHash -Event $third
        $lines[2] = $third | ConvertTo-Json -Depth 50 -Compress
        $lines | Set-Content -LiteralPath $observation.ledger_path -Encoding utf8

        $inspection = & $observerRunnerPath -Action Inspect -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50

        $inspection.ledger_integrity | Should -Be 'tampered'
        $inspection.last_trusted_sequence | Should -Be 2
    }

    It 'records an explicit stage failure as a terminal event with actual metrics' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'stage-failed')
        $runtimeRoot = Join-Path $TestDrive 'runtime-stage-failed'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'failed-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'failed-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root -Status failed -WithoutQuality

        $failed = & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson |
            ConvertFrom-Json -Depth 50

        $failed.state | Should -Be 'failed'
        $failed.stage_counts.failed | Should -Be 1
        $failed.actual_totals.input_tokens | Should -Be 100
        $failed.reserved_totals.input_tokens | Should -Be 0
    }

    It 'rejects undeclared stage result fields before mutating Ledger' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'strict-result')
        $runtimeRoot = Join-Path $TestDrive 'runtime-strict-result'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'strict-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'strict-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 50
        $document | Add-Member -NotePropertyName undeclared -NotePropertyValue $true
        $document | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $resultPath -Encoding utf8

        $threw = $false
        try { & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 2
    }

    It 'rechecks evidence hashes during final evaluation' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'evidence-drift')
        $runtimeRoot = Join-Path $TestDrive 'runtime-evidence-drift'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $prepareStart = Write-TestStageRequest -Path (Join-Path $TestDrive 'drift-prepare-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $prepareStart -AsJson | Out-Null
        $prepareResult = Write-TestStageResult -Path (Join-Path $TestDrive 'drift-prepare-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $prepareResult -AsJson | Out-Null
        $verifyStart = Write-TestStageRequest -Path (Join-Path $TestDrive 'drift-verify-start.json') -Observation $observation -StageId 'verify' -StartedAt '2026-07-18T01:00:02+09:00' -ModelCalls 0 -InputTokens 0 -OutputTokens 0 -CostMicrounits 0
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $verifyStart -AsJson | Out-Null
        $verifyResult = Write-TestStageResult -Path (Join-Path $TestDrive 'drift-verify-result.json') -Observation $observation -StageId 'verify' -EvidenceRoot $fixture.evidence_root -FinishedAt '2026-07-18T01:00:03+09:00' -ModelCalls 0 -InputTokens 0 -OutputTokens 0 -CostMicrounits 0 -WithoutQuality
        & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $verifyResult -AsJson | Out-Null
        'changed after stage acceptance' | Set-Content -LiteralPath (Join-Path $fixture.evidence_root 'prepare-evidence.txt') -Encoding utf8

        $threw = $false
        try { & $observerRunnerPath -Action Evaluate -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 5
    }

    It 'rejects subject contract drift before recording another event' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'subject-drift')
        $runtimeRoot = Join-Path $TestDrive 'runtime-subject-drift'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        '{"changed":true}' | Set-Content -LiteralPath $fixture.subject_contract_path -Encoding utf8
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'subject-drift-start.json') -Observation $observation -StageId 'prepare'

        $threw = $false
        try { & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 1
    }

    It 'rejects a subject contract that does not match the declared kind schema' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'subject-schema')
        [ordered]@{ schema_version = '0.1'; graph_id = 'agent-os-graph-20260718-010000-aaaaaaaa' } |
            ConvertTo-Json | Set-Content -LiteralPath $fixture.subject_contract_path -Encoding utf8
        $spec = Get-Content -LiteralPath $fixture.spec_path -Raw | ConvertFrom-Json -Depth 50
        $spec.subject.contract_sha256 = (Get-FileHash -LiteralPath $fixture.subject_contract_path -Algorithm SHA256).Hash
        $spec | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $fixture.spec_path -Encoding utf8
        $runtimeRoot = Join-Path $TestDrive 'runtime-subject-schema'

        $threw = $false
        try { & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        Test-Path -LiteralPath $runtimeRoot | Should -Be $false
    }

    It 'rejects a valid subject contract whose ID differs from the declared subject ID' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'subject-id')
        $spec = Get-Content -LiteralPath $fixture.spec_path -Raw | ConvertFrom-Json -Depth 50
        $spec.subject.subject_id = 'agent-os-graph-20260718-010000-bbbbbbbb'
        $spec | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $fixture.spec_path -Encoding utf8
        $runtimeRoot = Join-Path $TestDrive 'runtime-subject-id'

        $threw = $false
        try { & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        Test-Path -LiteralPath $runtimeRoot | Should -Be $false
    }

    It 'rejects credential-like specification text before creating runtime state' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'credential-spec')
        $spec = Get-Content -LiteralPath $fixture.spec_path -Raw | ConvertFrom-Json -Depth 50
        $spec.observation_key = 'password: hunter2'
        $spec | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $fixture.spec_path -Encoding utf8
        $runtimeRoot = Join-Path $TestDrive 'runtime-credential-spec'

        $threw = $false
        try { & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        Test-Path -LiteralPath $runtimeRoot | Should -Be $false
    }

    It 'rejects cyclic stage dependencies before creating runtime state' {
        $stages = @(
            [ordered]@{ stage_id = 'a'; depends_on = @('b'); quality_gates = @() },
            [ordered]@{ stage_id = 'b'; depends_on = @('a'); quality_gates = @() }
        )
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'cycle') -Stages $stages
        $runtimeRoot = Join-Path $TestDrive 'runtime-cycle'

        $threw = $false
        try { & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        Test-Path -LiteralPath $runtimeRoot | Should -Be $false
    }

    It 'rejects concurrent mutation while the observation lock is held' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'lock')
        $runtimeRoot = Join-Path $TestDrive 'runtime-lock'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'lock-start.json') -Observation $observation -StageId 'prepare'
        $lockPath = Join-Path $observation.observation_path '.observer.lock'
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $threw = $false
            try { & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath | Out-Null }
            catch { $threw = $true }
            $threw | Should -Be $true
            @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 1
        }
        finally { $lock.Dispose() }
    }

    It 'rejects an observation directory junction inside RuntimeRoot' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'junction')
        $runtimeRoot = Join-Path $TestDrive 'runtime-junction'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $junctionPath = Join-Path $runtimeRoot 'agent-os-observation-20260718-010000-deadbeef'
        New-Item -ItemType Junction -Path $junctionPath -Target $observation.observation_path | Out-Null

        $threw = $false
        try { & $observerRunnerPath -Action Inspect -ObservationPath $junctionPath -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'junction-start.json') -Observation $observation -StageId 'prepare'
        $realLockPath = Join-Path $observation.observation_path '.observer.lock'
        Test-Path -LiteralPath $realLockPath | Should -Be $true
        $lockLength = (Get-Item -LiteralPath $realLockPath).Length
        $threw = $false
        try { & $observerRunnerPath -Action StartStage -ObservationPath $junctionPath -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        (Get-Item -LiteralPath $realLockPath).Length | Should -Be $lockLength
    }

    It 'rejects a duration that does not match the recorded stage timestamps' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'duration-mismatch')
        $runtimeRoot = Join-Path $TestDrive 'runtime-duration-mismatch'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'duration-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'duration-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root -DurationMs 999

        $threw = $false
        try { & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 2
    }

    It 'rejects non-zero cost without hash-bound cost evidence' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'cost-evidence')
        $runtimeRoot = Join-Path $TestDrive 'runtime-cost-evidence'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'cost-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'cost-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root
        $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 50
        $document.cost_evidence = [Collections.Generic.List[object]]::new()
        $document | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $resultPath -Encoding utf8

        $threw = $false
        try { & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        @(Get-Content -LiteralPath $observation.ledger_path).Count | Should -Be 2
    }

    It 'fails quality closed when a declared measurement is missing' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'missing-measurement')
        $runtimeRoot = Join-Path $TestDrive 'runtime-missing-measurement'
        $observation = & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot -AsJson |
            ConvertFrom-Json -Depth 50
        $requestPath = Write-TestStageRequest -Path (Join-Path $TestDrive 'missing-start.json') -Observation $observation -StageId 'prepare'
        & $observerRunnerPath -Action StartStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageRequestPath $requestPath -AsJson | Out-Null
        $resultPath = Write-TestStageResult -Path (Join-Path $TestDrive 'missing-result.json') -Observation $observation -StageId 'prepare' -EvidenceRoot $fixture.evidence_root -WithoutQuality

        $blocked = & $observerRunnerPath -Action FinishStage -ObservationPath $observation.observation_path -RuntimeRoot $runtimeRoot -StageResultPath $resultPath -AsJson |
            ConvertFrom-Json -Depth 50
        $blocked.state | Should -Be 'blocked_quality'
    }

    It 'rejects RuntimeRoot when an existing ancestor is a junction' {
        $fixture = New-TestObservationSpec -Root (Join-Path $TestDrive 'runtime-junction-ancestor')
        $realRoot = Join-Path $TestDrive 'real-observation-root'
        New-Item -ItemType Directory -Path $realRoot -Force | Out-Null
        $junctionRoot = Join-Path $TestDrive 'observation-root-junction'
        New-Item -ItemType Junction -Path $junctionRoot -Target $realRoot | Out-Null
        $runtimeRoot = Join-Path $junctionRoot 'nested-runtime'

        $threw = $false
        try { & $observerRunnerPath -Action Initialize -ObservationSpecPath $fixture.spec_path -RuntimeRoot $runtimeRoot | Out-Null }
        catch { $threw = $true }
        $threw | Should -Be $true
        Test-Path -LiteralPath (Join-Path $realRoot 'nested-runtime') | Should -Be $false
    }
}
