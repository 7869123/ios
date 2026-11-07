$ErrorActionPreference = 'Stop'
$aiutilityRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('Swift is not installed. No Swift tests ran. See BUILD.md for requirements.')
    exit 2
}
& swift --version
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& swift test --package-path (Join-Path $aiutilityRoot 'Packages/AIUtilityCore')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($IsMacOS) {
    & swift test --package-path (Join-Path $aiutilityRoot 'Packages/AIUtilityAppleServices')
    exit $LASTEXITCODE
}
