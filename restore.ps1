[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Backup,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ManagedFiles = @(
    "options/laf.xml",
    "options/ui.lnf.xml",
    "options/editor.xml",
    "options/colors.scheme.xml",
    "colors/Ordered Dark.icls"
)

function Stop-WithError([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not $Force) {
    $RunningIdea = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @("idea64", "idea") }
    if ($RunningIdea) {
        Stop-WithError "IntelliJ IDEA is running. Close it completely and retry."
    }
}

$Backup = [System.IO.Path]::GetFullPath($Backup)
$TargetFile = Join-Path $Backup ".target-dir"
if (-not (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
    Stop-WithError "Invalid backup directory: $Backup"
}

$Target = (Get-Content -LiteralPath $TargetFile -TotalCount 1).Trim()
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Stop-WithError "Original IDEA config directory does not exist: $Target"
}

$CreatedFilesPath = Join-Path $Backup ".created-files"
$CreatedFiles = @()
if (Test-Path -LiteralPath $CreatedFilesPath -PathType Leaf) {
    $CreatedFiles = @(Get-Content -LiteralPath $CreatedFilesPath)
}

foreach ($RelativePath in $ManagedFiles) {
    $BackupFile = Join-Path $Backup $RelativePath
    $DestinationFile = Join-Path $Target $RelativePath
    if (Test-Path -LiteralPath $BackupFile -PathType Leaf) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationFile) -Force | Out-Null
        Copy-Item -LiteralPath $BackupFile -Destination $DestinationFile -Force
    }
    elseif ($CreatedFiles -contains $RelativePath) {
        Remove-Item -LiteralPath $DestinationFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Restore complete: $Target"
