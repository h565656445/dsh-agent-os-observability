[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Initialize', 'StartStage', 'FinishStage', 'Evaluate', 'Inspect', 'Recover')]
    [string]$Action,
    [string]$ObservationSpecPath,
    [string]$RuntimeRoot,
    [string]$ObservationPath,
    [string]$StageRequestPath,
    [string]$StageResultPath,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $projectRoot 'runtime\agent_os_observations'
}

Import-Module (Join-Path $projectRoot 'src\AgentOSObservability.psm1') -Force

$arguments = @{ Action = $Action; RuntimeRoot = $RuntimeRoot }
foreach ($name in @('ObservationSpecPath', 'ObservationPath', 'StageRequestPath', 'StageResultPath')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $arguments[$name] = Get-Variable -Name $name -ValueOnly
    }
}
$result = Invoke-AgentOSObservation @arguments
if ($AsJson) {
    return $result | ConvertTo-Json -Depth 50
}
return $result
