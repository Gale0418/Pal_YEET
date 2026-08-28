[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PalworldRoot = 'D:\Program Files (x86)\Steam\steamapps\common\Palworld'
)

$ErrorActionPreference = 'Stop'
$palworldFull = [IO.Path]::GetFullPath($PalworldRoot)
$modsRoot = Join-Path $palworldFull 'Mods'
$settingsPath = Join-Path $modsRoot 'PalModSettings.ini'
$managedManifest = Join-Path $modsRoot 'ManagedMods\YEET\InstallManifest.json'
$modsTextPath = Join-Path $modsRoot 'NativeMods\UE4SS\Mods\mods.txt'

foreach ($required in @($settingsPath, $managedManifest, $modsTextPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Managed YEET is not ready; missing: $required"
    }
}

$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
if ($settings -notmatch '(?m)^ActiveModList=YEET\s*$') {
    throw 'Enable YEET in Palworld Mod Management before switching off YEETCaravanCore.'
}

$modsText = Get-Content -LiteralPath $modsTextPath -Raw -Encoding UTF8
if ($modsText -notmatch '(?m)^YEETCaravanCore\s*:\s*1\s*$') {
    Write-Output 'YEETSWITCH: legacy YEETCaravanCore is already disabled.'
    return
}

$updated = [regex]::Replace($modsText, '(?m)^YEETCaravanCore\s*:\s*1\s*$', 'YEETCaravanCore : 0')
$backupPath = "$modsTextPath.YEET-backup"
if ($PSCmdlet.ShouldProcess($modsTextPath, 'Disable legacy YEETCaravanCore after managed YEET validation')) {
    Copy-Item -LiteralPath $modsTextPath -Destination $backupPath -Force
    Set-Content -LiteralPath $modsTextPath -Value $updated -Encoding UTF8 -NoNewline
    Write-Output 'YEETSWITCH: PASS legacy YEETCaravanCore disabled.'
    Write-Output "backup=$backupPath"
}
