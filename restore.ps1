[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Backup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

$RunningIdea = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -in @("idea64", "idea") }
if ($RunningIdea) {
    Fail "IntelliJ IDEA is running. Close it completely, then run this script again."
}

$Backup = [System.IO.Path]::GetFullPath($Backup)
$TargetRecord = Join-Path $Backup ".target-dir"
if (-not (Test-Path -LiteralPath $TargetRecord -PathType Leaf)) {
    Fail "Invalid backup directory: $Backup"
}

$Target = (Get-Content -LiteralPath $TargetRecord -TotalCount 1).Trim()
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Fail "Original IDEA config directory was not found: $Target"
}

$ManagedFiles = @(
    "options/laf.xml",
    "options/colors.scheme.xml",
    "colors/Ordered Dark.icls",
    "colors/OrderedDark.icls"
)

$CreatedFiles = @()
$CreatedRecord = Join-Path $Backup ".created-files"
if (Test-Path -LiteralPath $CreatedRecord -PathType Leaf) {
    $CreatedFiles = @(Get-Content -LiteralPath $CreatedRecord)
}

foreach ($RelativePath in $ManagedFiles) {
    $BackupFile = Join-Path $Backup $RelativePath
    $Destination = Join-Path $Target $RelativePath
    if (Test-Path -LiteralPath $BackupFile -PathType Leaf) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
        Copy-Item -LiteralPath $BackupFile -Destination $Destination -Force
    }
    elseif ($CreatedFiles -contains $RelativePath) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Restore completed: $Target"
