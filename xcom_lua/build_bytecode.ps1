[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$LuaJit,
    [switch]$Incremental
)

$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $sourceRoot "bytecode"
}
if ([string]::IsNullOrWhiteSpace($LuaJit)) {
    # Self-contained: the checked-in runtime LuaJIT compiles bytecode when
    # given the vendored jit-tools Lua modules (libs/jit-tools).  We no longer
    # depend on an external openresty directory.
    $candidates = @(
        (Join-Path $sourceRoot "runtime\luajit.exe"),
        (Join-Path $sourceRoot "runtime\luvjit.exe")
    )
    $LuaJit = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not (Test-Path -LiteralPath $LuaJit)) {
    throw "LuaJIT runtime not found: $LuaJit"
}
$LuaJit = (Resolve-Path -LiteralPath $LuaJit).Path
# jit.* modules (bcsave.lua) live in the vendored jit-tools; expose them so
# runtime\luajit.exe -b can emit bytecode without an external LuaJIT install.
$env:LUA_PATH = (Join-Path $sourceRoot "libs\jit-tools\?.lua") + ";" +
                (Join-Path $sourceRoot "libs\jit-tools\?\init.lua") + ";;"
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$sources = @(
    (Join-Path $sourceRoot "main.lua")
) + @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot "core") -Filter "*.lua" -File) +
    @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot "ui") -Filter "*.lua" -File)

foreach ($entry in $sources) {
    $source = if ($entry -is [System.IO.FileInfo]) { $entry.FullName } else { $entry }
    $relative = $source.Substring($sourceRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $OutputRoot ([System.IO.Path]::ChangeExtension($relative, ".ljbc"))
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    # -Incremental: skip when the bytecode is already newer than the source,
    # so a retune/edit-only pass does not recompile unchanged modules.  Source
    # and bytecode must stay in lock-step — when in doubt rebuild all.
    if ($Incremental -and (Test-Path -LiteralPath $destination)) {
        $srcTime = (Get-Item -LiteralPath $source).LastWriteTime
        $dstTime = (Get-Item -LiteralPath $destination).LastWriteTime
        if ($dstTime -ge $srcTime) {
            Write-Host ("skip {0} (bytecode current)" -f $relative)
            continue
        }
    }

    & $LuaJit -b $source $destination
    if ($LASTEXITCODE -ne 0) {
        throw "LuaJIT bytecode compilation failed: $relative"
    }
    Write-Host ("compiled {0}" -f $relative)
}

Write-Host ("bytecode output: {0}" -f (Resolve-Path -LiteralPath $OutputRoot))
