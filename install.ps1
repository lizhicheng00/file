[CmdletBinding()]
param(
    [string]$Target,
    [string]$Project,
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

if ([string]::IsNullOrWhiteSpace($Target)) {
    $CurrentDirectory = (Get-Location).Path
    $CurrentName = Split-Path -Leaf $CurrentDirectory
    if ($CurrentName -like "IntelliJIdea*" -or $CurrentName -like "IdeaIC*") {
        $Target = $CurrentDirectory
    }
    else {
        $JetBrainsRoot = Join-Path $env:APPDATA "JetBrains"
        if (-not (Test-Path -LiteralPath $JetBrainsRoot -PathType Container)) {
            Stop-WithError "IDEA config root was not found. Use -Target PATH."
        }
        $Candidate = Get-ChildItem -LiteralPath $JetBrainsRoot -Directory |
            Where-Object { $_.Name -like "IntelliJIdea*" -or $_.Name -like "IdeaIC*" } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($null -eq $Candidate) {
            Stop-WithError "IDEA config directory was not found. Use -Target PATH."
        }
        $Target = $Candidate.FullName
    }
}

$Target = [System.IO.Path]::GetFullPath($Target)
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Stop-WithError "Target directory does not exist: $Target"
}

$SourceRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "settings/options/laf.xml") -PathType Leaf)) {
    Stop-WithError "Run install.ps1 from a complete clone of this repository."
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDirectory = Join-Path $Target "ordered-dark-backups/$Timestamp"
New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
Set-Content -LiteralPath (Join-Path $BackupDirectory ".target-dir") -Value $Target

foreach ($RelativePath in $ManagedFiles) {
    $SourceFile = Join-Path $SourceRoot "settings/$RelativePath"
    $TargetFile = Join-Path $Target $RelativePath
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        Stop-WithError "Missing settings file: $SourceFile"
    }

    if (Test-Path -LiteralPath $TargetFile -PathType Leaf) {
        $BackupFile = Join-Path $BackupDirectory $RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $BackupFile) -Force | Out-Null
        Copy-Item -LiteralPath $TargetFile -Destination $BackupFile -Force
    }
    else {
        Add-Content -LiteralPath (Join-Path $BackupDirectory ".created-files") -Value $RelativePath
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $TargetFile) -Force | Out-Null
    Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force
}

if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $Project = [System.IO.Path]::GetFullPath($Project)
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        Stop-WithError "Project directory does not exist: $Project"
    }
    $EditorConfig = Join-Path $Project ".editorconfig"
    if (Test-Path -LiteralPath $EditorConfig -PathType Leaf) {
        Copy-Item -LiteralPath $EditorConfig -Destination "$EditorConfig.before-ordered-dark-$Timestamp" -Force
    }
    Copy-Item -LiteralPath (Join-Path $SourceRoot "project/.editorconfig") -Destination $EditorConfig -Force
    Write-Host "Project settings installed: $EditorConfig"
}

Write-Host ""
Write-Host "Installation complete."
Write-Host "IDEA config: $Target"
Write-Host "Backup: $BackupDirectory"
Write-Host "Start IntelliJ IDEA now. The UI theme is forced to Darcula."
