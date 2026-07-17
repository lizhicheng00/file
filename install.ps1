[CmdletBinding()]
param(
    [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Write-Utf8([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content + [Environment]::NewLine, $Utf8NoBom)
}

$RunningIdea = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -in @("idea64", "idea") }
if ($RunningIdea) {
    Fail "IntelliJ IDEA is running. Close it completely, then run this script again."
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Fail "APPDATA is not available. Use -Target to specify the IDEA config directory."
    }
    $Target = Join-Path $env:APPDATA "JetBrains/IntelliJIdea2025.3"
}

$Target = [System.IO.Path]::GetFullPath($Target)
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Fail "IDEA 2025.3 config directory was not found: $Target. Start IDEA 2025.3 once, close it, and retry."
}

$Files = [ordered]@{
    "options/laf.xml" = @'
<application>
  <component name="LafManager" autodetect="false">
    <laf themeId="Islands Dark" />
  </component>
</application>
'@
    "options/colors.scheme.xml" = @'
<application>
  <component name="EditorColorsManagerImpl">
    <global_color_scheme name="Islands Dark" />
  </component>
</application>
'@
}

$LegacyFiles = @(
    "colors/Ordered Dark.icls",
    "colors/OrderedDark.icls"
)

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = Join-Path $Target "islands-dark-backups/$Timestamp"
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
Write-Utf8 (Join-Path $Backup ".target-dir") $Target

$CreatedFiles = @()
foreach ($RelativePath in @($Files.Keys) + $LegacyFiles) {
    $CurrentFile = Join-Path $Target $RelativePath
    if (Test-Path -LiteralPath $CurrentFile -PathType Leaf) {
        $BackupFile = Join-Path $Backup $RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $BackupFile) -Force | Out-Null
        Copy-Item -LiteralPath $CurrentFile -Destination $BackupFile -Force
    }
    elseif ($Files.Contains($RelativePath)) {
        $CreatedFiles += $RelativePath
    }
}

foreach ($Entry in $Files.GetEnumerator()) {
    Write-Utf8 (Join-Path $Target $Entry.Key) $Entry.Value
}

foreach ($RelativePath in $LegacyFiles) {
    Remove-Item -LiteralPath (Join-Path $Target $RelativePath) -Force -ErrorAction SilentlyContinue
}

if ($CreatedFiles.Count -gt 0) {
    Write-Utf8 (Join-Path $Backup ".created-files") ($CreatedFiles -join [Environment]::NewLine)
}

try {
    [xml]$Laf = Get-Content -LiteralPath (Join-Path $Target "options/laf.xml") -Raw
    [xml]$Colors = Get-Content -LiteralPath (Join-Path $Target "options/colors.scheme.xml") -Raw
}
catch {
    Fail "The generated XML could not be parsed. Restore from: $Backup"
}

if ($Laf.application.component.laf.themeId -ne "Islands Dark") {
    Fail "UI theme verification failed. Restore from: $Backup"
}
if ($Colors.application.component.global_color_scheme.name -ne "Islands Dark") {
    Fail "Editor color scheme verification failed. Restore from: $Backup"
}

Write-Host ""
Write-Host "IntelliJ IDEA 2025.3 theme configuration completed."
Write-Host "Config: $Target"
Write-Host "Backup: $Backup"
Write-Host "UI theme: Islands Dark"
Write-Host "Editor color scheme: Islands Dark"
Write-Host "Start IntelliJ IDEA now."
