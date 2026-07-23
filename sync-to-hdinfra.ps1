[CmdletBinding()]
param(
    [string]$Source = 'D:\code\HDSpaceService\relay-controller',
    [string]$Destination = 'D:\code\HDInfraService\relay-controller',
    [switch]$Mirror,
    [switch]$AllowDirtySource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

try {
    $sourceRoot = Get-NormalizedPath -Path $Source
    $destinationRoot = Get-NormalizedPath -Path $Destination

    if ($sourceRoot.Equals($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and destination must be different directories.'
    }

    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Source directory does not exist: $sourceRoot"
    }

    & git -C $sourceRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Source directory is not a Git working tree: $sourceRoot"
    }

    $workingTreeChanges = @(& git -C $sourceRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the source working tree.'
    }

    if ($workingTreeChanges.Count -gt 0 -and -not $AllowDirtySource) {
        Write-Host 'The source working tree has local changes:' -ForegroundColor Yellow
        $workingTreeChanges | ForEach-Object { Write-Host "  $_" }
        throw 'Commit or stash these changes first, or rerun with -AllowDirtySource.'
    }

    Write-Host "Pulling: $sourceRoot" -ForegroundColor Cyan
    & git -C $sourceRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        throw 'Git pull failed. The destination was not changed.'
    }

    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    }

    $copyMode = if ($Mirror) { '/MIR' } else { '/E' }
    if ($Mirror) {
        Write-Host 'Mirror mode is enabled: destination-only files may be deleted.' -ForegroundColor Yellow
    }

    Write-Host "Copying to: $destinationRoot" -ForegroundColor Cyan
    $robocopyArguments = @(
        $sourceRoot
        $destinationRoot
        '*'
        $copyMode
        '/COPY:DAT'
        '/DCOPY:DAT'
        '/R:2'
        '/W:1'
        '/XJ'
        '/XD'
        '.git'
        '.idea'
        '.gradle'
        'target'
        'build'
        'out'
        '/XF'
        '*.iml'
    )

    & robocopy @robocopyArguments
    $robocopyExitCode = $LASTEXITCODE

    # Robocopy exit codes 0 through 7 are successful states.
    if ($robocopyExitCode -ge 8) {
        throw "Robocopy failed with exit code $robocopyExitCode."
    }

    Write-Host 'Pull and copy completed successfully.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
