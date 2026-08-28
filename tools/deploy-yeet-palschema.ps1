[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameRoot = 'D:\Program Files (x86)\Steam\steamapps\common\Palworld'
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\PalSchema\mods\YEETTerminal'
$candidates = @(
    (Join-Path $GameRoot 'Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods'),
    (Join-Path $GameRoot 'Mods\NativeMods\UE4SS\Mods\PalSchema\mods')
)
$targetRoot = $candidates | Where-Object { Test-Path -LiteralPath (Split-Path $_ -Parent) } | Select-Object -First 1

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "YEET PalSchema source not found: $source"
}
if (-not $targetRoot) {
    throw 'PalSchema installation was not found. Install the PalSchema dev build first; no files were copied.'
}

$target = Join-Path $targetRoot 'YEETTerminal'
if ($PSCmdlet.ShouldProcess($target, 'Deploy YEETTerminal PalSchema source')) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    Write-Output "Deployed YEETTerminal PalSchema source to $target"
}
else {
    Write-Output "WhatIf: would deploy YEETTerminal PalSchema source to $target"
}
