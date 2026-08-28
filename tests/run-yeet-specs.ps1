[CmdletBinding()]
param([string]$Workspace = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$testsRoot = Join-Path $Workspace 'tests'
$python = (Get-Command python -ErrorAction Stop).Source

foreach ($test in Get-ChildItem -LiteralPath $testsRoot -Filter '*_spec.py' -File | Sort-Object Name) {
    Write-Output ("RUN {0}" -f $test.Name)
    & $python $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Python spec failed: $($test.Name)" }
}

$luaCommand = Get-Command lua -ErrorAction SilentlyContinue
if ($null -eq $luaCommand) { $luaCommand = Get-Command luajit -ErrorAction SilentlyContinue }
if ($null -eq $luaCommand) {
    Write-Output 'LUA SPECS: standalone lua/luajit unavailable; trying Lupa runner'
    & $python (Join-Path $testsRoot 'run-lua-specs.py')
    if ($LASTEXITCODE -ne 0) { throw 'Lupa Lua spec runner failed' }
} else {
    foreach ($test in Get-ChildItem -LiteralPath $testsRoot -Filter '*_spec.lua' -File | Sort-Object Name) {
        Write-Output ("RUN {0}" -f $test.Name)
        & $luaCommand.Source $test.FullName
        if ($LASTEXITCODE -ne 0) { throw "Lua spec failed: $($test.Name)" }
    }
}

Write-Output 'YEET SPECS: PASS'
