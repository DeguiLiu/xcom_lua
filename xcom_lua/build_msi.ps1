# build_msi.ps1 - wrap the staged release tree in a Windows installer.
#
# Run build_release.ps1 first: this consumes dist/xcom-release-v<ver>/, not the
# build outputs, so the MSI and the zip always install identical bytes.
#
#   pwsh -File xcom_lua/build_msi.ps1 [-Version 1.4.5] [-Stage <dir>]
#
# Machine-wide install under Program Files, so installing asks for elevation.
# The app writes imgui.ini and its logs next to the executable, so uninstall
# leaves the install root behind when it still holds user files.
#
# Requires the WiX 3.x toolset (candle.exe/light.exe). Point WIX_BIN at it, or
# let the script find it under %LOCALAPPDATA%\Programs\wix.
[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Stage = ""
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path          # xcom_lua/
$repo = Split-Path $root -Parent

if ([string]::IsNullOrWhiteSpace($Version)) {
    $cmake = Join-Path $repo "CMakeLists.txt"
    $m = Select-String -LiteralPath $cmake -Pattern 'project\(XCOM VERSION ([0-9]+\.[0-9]+\.[0-9]+)' |
         Select-Object -First 1
    if (-not $m) { throw "cannot read the XCOM version from $cmake" }
    $Version = $m.Matches[0].Groups[1].Value
}

if ([string]::IsNullOrWhiteSpace($Stage)) {
    $Stage = Join-Path $repo "dist/xcom-release-v$Version"
}
$Stage = (Resolve-Path -LiteralPath $Stage).Path
if (-not (Test-Path -LiteralPath (Join-Path $Stage "runtime\xcom.exe"))) {
    throw "stage '$Stage' has no runtime\xcom.exe - run build_release.ps1 first"
}

# ---- locate the WiX toolset ----
$wix = $env:WIX_BIN
if ([string]::IsNullOrWhiteSpace($wix)) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\wix"),
        (Join-Path ${env:ProgramFiles(x86)} "WiX Toolset v3.14\bin"),
        (Join-Path $env:ProgramFiles "WiX Toolset v3.14\bin")
    )
    $wix = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ "candle.exe") } |
           Select-Object -First 1
}
if (-not $wix) {
    throw "WiX not found. Set WIX_BIN to the directory holding candle.exe/light.exe."
}
$candle = Join-Path $wix "candle.exe"
$light  = Join-Path $wix "light.exe"
Write-Host "wix      : $wix"

$installer = Join-Path $root "installer"
$objDir    = Join-Path $installer "obj"
if (Test-Path -LiteralPath $objDir) { Remove-Item -LiteralPath $objDir -Recurse -Force }
New-Item -ItemType Directory -Path $objDir | Out-Null

# ---- harvest the staged tree into a component group ----
# Every build regenerates files.wxs with deterministic GUIDs (-gg -g1) so the
# component identities survive a rebuild; that is what lets MajorUpgrade replace
# an older install instead of stacking a second copy beside it.
#
# -arch x64 must match the candle -arch below. heat defaults to x86 and marks
# every harvested component 32-bit, which then collides with the 64-bit
# Program Files directory layout (ICE80).
$filesWxs = Join-Path $installer "files.wxs"
& (Join-Path $wix "heat.exe") dir $Stage `
    -cg XcomFiles -dr INSTALLFOLDER -gg -g1 -sfrag -srd -sreg `
    -arch x64 -var var.SourceDir `
    -out $filesWxs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "heat.exe failed" }
Write-Host "harvested: $((Select-String -LiteralPath $filesWxs -Pattern '<Component ').Count) components"

# ---- compile ----
$relStage = $Stage -replace '\\', '/'
$candleArgs = @(
    "-nologo", "-arch", "x64",
    "-dProductVersion=$Version",
    "-dSourceDir=$relStage",
    "-ext", "WixUIExtension",
    "-out", "$objDir\",
    (Join-Path $installer "xcom.wxs"), $filesWxs
)
& $candle @candleArgs
if ($LASTEXITCODE -ne 0) { throw "candle.exe failed" }

# ---- link ----
$msi = Join-Path $repo "dist\xcom-v$Version-x64.msi"
if (Test-Path -LiteralPath $msi) { Remove-Item -LiteralPath $msi -Force }

# ICE60/ICE61 note that versioned files carry no language or that a version is
# below a previous one; both are advisory and neither affects installation.
$lightArgs = @(
    "-nologo",
    "-ext", "WixUIExtension",
    "-cultures:zh-CN",
    "-loc", (Join-Path $installer "loc\WixUI_zh-CN.wxl"),
    "-sice:ICE60",
    "-sice:ICE61",
    "-out", $msi,
    "-b", $Stage,
    (Join-Path $objDir "xcom.wixobj"),
    (Join-Path $objDir "files.wixobj")
)

& $light @lightArgs
if ($LASTEXITCODE -ne 0) { throw "light.exe failed" }

$mb = [math]::Round((Get-Item $msi).Length / 1MB, 2)
Write-Host "PACKAGED $msi ($mb MB)"
