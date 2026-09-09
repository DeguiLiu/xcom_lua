# build_release.ps1 - assemble the xcom_lua Windows release package.
#
# Layout (user opens the package and double-clicks xcom.exe at the root):
#   <pkg>/xcom.exe + xcom.ico          launcher at the ROOT (discoverable entry)
#   <pkg>/README.txt                    how to run
#   <pkg>/main.ljbc                    app entry (bytecode ONLY, no main.lua)
#   <pkg>/core|ui/*.ljbc               app modules (bytecode via build_bytecode.ps1;
#                                       no .lua source is shipped)
#   <pkg>/libs/                        vendored pure-Lua libraries (runtime dep)
#   <pkg>/scripts/                     user plugin scripts (.lua only, editable)
#   <pkg>/config.ini                   clean defaults (no [window] geometry)
#   <pkg>/runtime/                     DLLs + assets/ (layout.toml, fonts)
# Then compresses to dist/xcom-release-v<ver>.zip.
#
# Usage:  powershell -ExecutionPolicy Bypass -File build_release.ps1 [-Version 1.4.0]
#                                     [-SkipBytecode] [-OutDir <dir>]
[CmdletBinding()]
param(
    [string]$Version = "1.3.0",
    [switch]$SkipBytecode,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path          # xcom_lua/
$stage = if ($OutDir) { $OutDir } else { Join-Path (Split-Path $root -Parent) "dist/xcom-release-v$Version" }
Write-Host "staging: $stage"

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

# ---- Lua bytecode for main/core/ui (.ljbc preferred at require time) ----
$bytecodeRoot = Join-Path $env:TEMP "xcom_bc_$Version"
if (-not $SkipBytecode) {
    & (Join-Path $root "build_bytecode.ps1") -OutputRoot $bytecodeRoot | Out-Null
} elseif (Test-Path -LiteralPath $bytecodeRoot) {
    Remove-Item -LiteralPath $bytecodeRoot -Recurse -Force
    New-Item -ItemType Directory -Path $bytecodeRoot | Out-Null
}

function Copy-LuaTree([string]$name) {
    $srcDir = Join-Path $root $name
    $dstDir = Join-Path $stage $name
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    Get-ChildItem -LiteralPath $srcDir -Filter "*.lua" -File | ForEach-Object {
        # app modules ship as BYTECODE ONLY (no .lua source in the bundle): the
        # bytecode mirrors the source tree under <outputRoot>/<name>/<module>.ljbc.
        $bc = Join-Path $bytecodeRoot (Join-Path $name ($_.Name -replace '\.lua$', '.ljbc'))
        if (Test-Path -LiteralPath $bc) { Copy-Item -LiteralPath $bc -Destination $dstDir }
    }
    # subdirectories that carry modules (ui/, core/ have none today; keep flat
    # contract visible here on purpose so a stray folder never ships silently)
}

Copy-LuaTree "core"
Copy-LuaTree "ui"
$mainBc = Join-Path $bytecodeRoot "main.ljbc"
if (Test-Path -LiteralPath $mainBc) { Copy-Item -LiteralPath $mainBc -Destination $stage }

# ---- vendored libraries (.lua verbatim; no bytecode for third-party code) ----
Copy-Item -LiteralPath (Join-Path $root "libs") -Destination (Join-Path $stage "libs") -Recurse

# ---- plugin scripts (.lua only; user-editable code, never bytecode) ----
Copy-Item -LiteralPath (Join-Path $root "scripts") -Destination (Join-Path $stage "scripts") -Recurse

# ---- clean config.ini (defaults; no dev window geometry, no enabled scripts,
#      no COM port pin — the app regenerates/defaults on first run) ----
$cfg = @"
[display]
receive_window_bytes = 65536
timestamp = true
charset = ASCII
auto_clear_bytes = 0
auto_save = false
save_path =
pause_display = false

[script]
enabled =
auto_reload = false
autorun_console = false

[send]
crlf = false
autosend_period_ms = 10
receive_hex = false
hex = false

[serial]
baud_rate = 115200
data_bits = 8
stop_bits = 0
parity = 0
flow_control = 0
dtr_enable = false
rts_enable = false
"@
Set-Content -LiteralPath (Join-Path $stage "config.ini") -Value $cfg -Encoding ASCII

# ---- user-facing run instructions (中文，指导用户双击 xcom.exe) ----
$readme = @"
XCOM 串口调试工具

快速开始：
  1. 进入 runtime\ 目录，双击 xcom.exe 启动程序。
  2. 在上方选择串口（COM 口）、波特率等参数，点击「打开」。
  3. 在下方输入发送内容，点击「发送」。

提示：
  - 运行所需的 VC++ 运行库（vcruntime140.dll 等）已自带在 runtime/ 目录，
    无需单独安装 Redistributable。
  - 脚本插件放在 scripts/ 目录，可在「脚本控制台」启用。
  - 接收日志、快捷发送等设置会自动保存到 config.ini。
"@
Set-Content -LiteralPath (Join-Path $stage "README.txt") -Value $readme -Encoding UTF8

# ---- diagnostics launcher: XCOM_DEBUG=1 + stderr -> xcom_debug.log ----
# Ships so a user can capture the full diagnostic trace of a crash (the
# normal xcom.exe launcher hides the console and stderr goes nowhere).
Copy-Item -LiteralPath (Join-Path $root "run_debug.ps1") -Destination $stage

# ---- runtime bundle (launcher exe + DLLs + assets) ----
$rt = Join-Path $stage "runtime"
New-Item -ItemType Directory -Path $rt | Out-Null
foreach ($f in @("xcom.exe", "xcom.ico", "luvjit.exe", "luajit.exe",
                 "lua51.dll", "luv.dll", "xcom_core.dll", "xcom_imgui.dll",
                 "libiconv-2.dll", "README.md")) {
    $p = Join-Path (Join-Path $root "runtime") $f
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $rt }
    elseif ($f -ne "luajit.exe") { throw "missing runtime file: $p" }
}
Copy-Item -LiteralPath (Join-Path $root "runtime\assets") -Destination (Join-Path $rt "assets") -Recurse

# ---- MSVC CRT: the MSVC-built lua51.dll / xcom_core.dll / xcom_imgui.dll
# link against the VC runtime.  Bundle the redistributable CRT so the package
# runs on a clean machine without a separate vc_redist install.  Resolve the
# Redist directory from the same MSVC toolchain that built the DLLs.
#
# Trimmed to what the shipped binaries ACTUALLY import (dumpbin -DEPENDENTS,
# 2026-09-09 audit): vcruntime140 (C runtime, all four binaries),
# vcruntime140_1 (x64 exception unwinding helper, xcom_imgui/xcom_core),
# msvcp140 (C++ STL, xcom_imgui/xcom_core/xcom.exe).  The rest of the VC143
# Redist folder (msvcp140_1/_2/atomic_wait/codecvt_ids, concrt140, vccorlib140)
# is only pulled in by C++/WinRT, <codecvt>, PPL or std::atomic::wait code,
# none of which this app uses — verified no direct AND no transitive import.
# UCRT (api-ms-win-crt-*) is OS-provided on Win10+, not bundled.
$vcRedist = "D:\BuildTools\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT"
if (Test-Path -LiteralPath $vcRedist) {
    foreach ($crt in @("vcruntime140.dll", "vcruntime140_1.dll",
                       "msvcp140.dll")) {
        $src = Join-Path $vcRedist $crt
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $rt }
        else { throw "missing CRT component: $src" }
    }
    Write-Host "bundled MSVC VC143 CRT into runtime/ (trimmed to 3)"
} else {
    throw "MSVC Redist CRT not found under $vcRedist"
}

# Launcher + icon stay in runtime/ beside luvjit.exe (the launcher resolves
# <runtime>/luvjit.exe and <root>/main.ljbc relative to its own dir).

# ---- sanity gates ----
# 1. DLL freshness: imgui DLL must be the build output, not a stale copy.
$built = Get-Item (Join-Path $root "native\xcom_imgui\build\xcom_imgui.dll")
$shipped = Get-Item (Join-Path $rt "xcom_imgui.dll")
if ($shipped.LastWriteTime -lt $built.LastWriteTime) {
    throw "xcom_imgui.dll in runtime is OLDER than build output — copy build/xcom_imgui.dll to runtime first"
}
# 2. layout.toml must carry the zh language line (DLL reads runtime/assets copy).
$layout = Get-Content -LiteralPath (Join-Path $rt "assets\layout.toml") -Raw
if ($layout -notmatch 'language\s*=\s*"zh"') { throw "packaged layout.toml lacks [ui] language = zh" }
# 3. packaged smoke: the staged app modules are bytecode-only (no .lua), so
#    verify the main entry bytecode and a core module LOAD as .ljbc with the
#    staged runtime, exercising the require-prefers-.ljbc path end to end.
$fwd = ($stage -replace '\\', '/')
Push-Location $rt
& (Join-Path $rt "luvjit.exe") -e "package.path='$fwd/?.ljbc;$fwd/core/?.ljbc;$fwd/ui/?.ljbc;$fwd/core/?.lua;$fwd/ui/?.lua;'..package.path; assert(loadfile('$fwd/main.ljbc')); local ok,m=pcall(require,'script_engine'); assert(ok and m, 'script_engine require: '..tostring(m)); print('STAGE_PARSE_OK')"
if ($LASTEXITCODE -ne 0) { throw "packaged smoke failed" }
Pop-Location

# 3b. CRT closure gate: every vcruntime/msvcp/api-ms-win-crt import of the
# shipped binaries must resolve — either bundled in runtime/ (vcruntime140*,
# msvcp140*) or OS-provided (api-ms-win-crt-*, UCRT on Win10+).  Catches a
# future code change that drags in a trimmed-away component (e.g. PPL) before
# it ships as a "missing DLL" on a clean machine.
$dumpbin = "D:\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\dumpbin.exe"
if (Test-Path -LiteralPath $dumpbin) {
    foreach ($bin in (Get-ChildItem -LiteralPath $rt -File | Where-Object {
                      $_.Extension -in ".dll", ".exe" })) {
        $deps = & $dumpbin -DEPENDENTS $bin.FullName 2>$null |
            Select-String -Pattern '\S+140\S*\.dll' |
            ForEach-Object { ($_.Line.Trim() -split '\s+')[-1] } |
            Sort-Object -Unique
        foreach ($dep in $deps) {
            if ($dep -match '^(vcruntime140|msvcp140)') {
                if (-not (Test-Path -LiteralPath (Join-Path $rt $dep))) {
                    throw "CRT closure: $($bin.Name) imports $dep but it is not bundled"
                }
            }
            # concrt140/vccorlib140 would also need bundling if ever imported.
            if ($dep -match '^(concrt140|vccorlib140)') {
                throw "CRT closure: $($bin.Name) imports $dep (PPL/C++-CX code path) — add it to the CRT bundle list"
            }
        }
    }
    Write-Host "CRT closure OK (trimmed set covers all imports)"
}

# ---- zip (Compress-Archive -LiteralPath does NOT expand wildcards; -Path does) ----
$zip = Join-Path (Split-Path $stage -Parent) "xcom-release-v$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 2)
Write-Host "PACKAGED $zip ($mb MB)"
