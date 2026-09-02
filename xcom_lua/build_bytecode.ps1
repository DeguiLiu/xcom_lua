[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$LuaJit
)

$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $sourceRoot "bytecode"
}
if ([string]::IsNullOrWhiteSpace($LuaJit)) {
    $candidates = @(
        (Join-Path $sourceRoot "..\openresty-1.29.2.1-win64\luajit.exe"),
        (Join-Path $sourceRoot "runtime\luajit.exe"),
        (Join-Path $sourceRoot "runtime\luvjit.exe")
    )
    $LuaJit = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not (Test-Path -LiteralPath $LuaJit)) {
    throw "LuaJIT runtime not found: $LuaJit"
}
$LuaJit = (Resolve-Path -LiteralPath $LuaJit).Path
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
    & $LuaJit -b $source $destination
    if ($LASTEXITCODE -ne 0) {
        throw "LuaJIT bytecode compilation failed: $relative"
    }
    Write-Host ("compiled {0}" -f $relative)
}

Write-Host ("bytecode output: {0}" -f (Resolve-Path -LiteralPath $OutputRoot))
