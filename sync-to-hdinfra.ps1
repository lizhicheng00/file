Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = 'D:\code\HDSpaceService\relay-controller'
$destinationRoot = 'D:\code\HDInfraService\relay-controller'
$itemsToCopy = @(
    '.gitignore'
    '.mvn'
    'README.md'
    'docs'
    'pom.xml'
    'scripts'
    'src'
)

try {
    & git -C $sourceRoot fetch --quiet origin main *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Git fetch failed.'
    }

    & git -C $sourceRoot pull --quiet --ff-only origin main *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Git pull failed.'
    }

    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

    foreach ($item in $itemsToCopy) {
        $sourceItem = Join-Path $sourceRoot $item
        if (-not (Test-Path -LiteralPath $sourceItem)) {
            continue
        }

        $destinationItem = Join-Path $destinationRoot $item
        if (Test-Path -LiteralPath $sourceItem -PathType Container) {
            New-Item -ItemType Directory -Path $destinationItem -Force | Out-Null
            & robocopy $sourceItem $destinationItem /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NC /NS /NP *> $null

            if ($LASTEXITCODE -ge 8) {
                throw "Failed to copy directory: $item"
            }
        }
        else {
            Copy-Item -LiteralPath $sourceItem -Destination $destinationItem -Force
        }
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
