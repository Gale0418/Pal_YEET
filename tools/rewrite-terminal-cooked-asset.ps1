[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DonorAsset,

    [Parameter(Mandatory = $true)]
    [string] $UAssetApiDll,

    [string] $UnrealPak = 'D:\EPIC\UE_5.1\Engine\Binaries\Win64\UnrealPak.exe',

    [string] $TargetPackage = 'BP_YEETTerminal'
)

$ErrorActionPreference = 'Stop'

function Resolve-File([string] $Path, [string] $Description) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Description is not a file: $Path"
    }
    return $resolved.Path
}

function Get-NameText($Name) {
    if ($null -eq $Name) { return '' }
    if ($Name.PSObject.Properties.Name -contains 'Value') {
        return $Name.Value.ToString()
    }
    return $Name.ToString()
}

function Get-NameMapText($Asset) {
    return @($Asset.GetNameMapIndexList() | ForEach-Object { Get-NameText $_ })
}

function Get-AsciiTokens([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return @([regex]::Matches($text, '[A-Za-z0-9_./-]{4,}') |
        ForEach-Object Value | Select-Object -Unique)
}

function Invoke-Captured([string] $FileName, [string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [ordered]@{
        exitCode = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
        combined = ($stdout + $stderr)
    }
}

$donor = Resolve-File $DonorAsset 'Donor .uasset'
$donorUexp = [IO.Path]::ChangeExtension($donor, '.uexp')
if (-not (Test-Path -LiteralPath $donorUexp -PathType Leaf)) {
    throw "Cooked Blueprint sidecar is missing: $donorUexp"
}
$api = Resolve-File $UAssetApiDll 'UAssetAPI DLL'
$pakTool = Resolve-File $UnrealPak 'UnrealPak'

$staging = Join-Path ([IO.Path]::GetTempPath()) ('yeet-terminal-rewrite-' + [guid]::NewGuid().ToString('N'))
$candidateDir = Join-Path $staging 'candidate\Pal\Content\Mods\YEET\Buildings'
New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null

try {
    Add-Type -Path $api
    $engineVersion = [UAssetAPI.UnrealTypes.EngineVersion]::VER_UE5_1
    $flags = [UAssetAPI.CustomSerializationFlags]::None

    # UE5.1 Palworld assets are unversioned cooked packages. UAssetAPI can parse this
    # donor without a usmap because this particular Blueprint has a readable name map.
    $source = [UAssetAPI.UAsset]::new($donor, $engineVersion, $null, $flags)
    if ($source.Exports.Count -lt 1) {
        throw 'Donor parsed but contains no exports; generated-class rewrite is unsafe.'
    }

    $oldPackageName = [IO.Path]::GetFileNameWithoutExtension($donor)
    $oldClassName = Get-NameText $source.Exports[0].ObjectName
    $oldFolderName = Get-NameText $source.FolderName
    if ([string]::IsNullOrWhiteSpace($oldFolderName)) {
        throw 'Donor parsed without FolderName; package-path rewrite cannot be verified.'
    }
    $targetFolderName = "/Game/Mods/YEET/Buildings/$TargetPackage"
    $targetClassName = "${TargetPackage}_C"

    # JSON round-trip preserves the cooked export raw data and name indices while
    # replacing the package path, generated class, CDO name, and package basename.
    $json = $source.SerializeJson($true)
    $json = $json.Replace($oldFolderName, $targetFolderName)
    $json = $json.Replace($oldClassName, $targetClassName)
    $json = $json.Replace($oldPackageName, $TargetPackage)
    $jsonPath = Join-Path $staging "$TargetPackage.rewrite.json"
    [IO.File]::WriteAllText($jsonPath, $json, [Text.UTF8Encoding]::new($false))

    $candidate = [UAssetAPI.UAsset]::DeserializeJson($json)
    $candidatePath = Join-Path $candidateDir "$TargetPackage.uasset"
    $candidate.Write($candidatePath)
    $candidateUexp = [IO.Path]::ChangeExtension($candidatePath, '.uexp')
    if (-not (Test-Path -LiteralPath $candidateUexp -PathType Leaf)) {
        throw "UAssetAPI wrote no .uexp sidecar: $candidateUexp"
    }

    # Re-open the generated pair with the same parser; this is the primary safety gate.
    $reopened = [UAssetAPI.UAsset]::new($candidatePath, $engineVersion, $null, $flags)
    $binaryEquality = $reopened.VerifyBinaryEquality()
    $nameMap = Get-NameMapText $reopened
    $donorExportNames = @($source.Exports | ForEach-Object { Get-NameText $_.ObjectName })
    $donorImportNames = @($source.Imports | ForEach-Object { Get-NameText $_.ObjectName })
    $exportNames = @($reopened.Exports | ForEach-Object { Get-NameText $_.ObjectName })
    $importNames = @($reopened.Imports | ForEach-Object { Get-NameText $_.ObjectName })
    $allNames = @($nameMap + $exportNames + $importNames)
    $oldResidue = @($allNames | Where-Object {
        $_ -eq $oldPackageName -or $_ -eq $oldClassName -or $_ -eq $oldFolderName -or
        $_ -like "Default__$oldClassName"
    } | Select-Object -Unique)
    $targetNames = @($allNames | Where-Object {
        $_ -eq $TargetPackage -or $_ -eq $targetClassName -or $_ -eq $targetFolderName -or
        $_ -eq "Default__$targetClassName"
    } | Select-Object -Unique)

    $tokenResidue = [Collections.Generic.List[string]]::new()
    foreach ($assetFile in @($candidatePath, $candidateUexp)) {
        $tokens = Get-AsciiTokens $assetFile
        foreach ($token in $tokens) {
            if ($token -eq $oldPackageName -or $token -eq $oldClassName -or $token -eq $oldFolderName -or
                $token -like "Default__$oldClassName") {
                $tokenResidue.Add("$([IO.Path]::GetFileName($assetFile)):$token")
            }
        }
    }

    $fileList = Join-Path $staging "$TargetPackage.paklist.txt"
    $pakPath = Join-Path $staging "$TargetPackage-rewrite.pak"
    $pakLines = @(
        ('"{0}" "../../../Pal/Content/Mods/YEET/Buildings/{1}.uasset"' -f $candidatePath, $TargetPackage),
        ('"{0}" "../../../Pal/Content/Mods/YEET/Buildings/{1}.uexp"' -f $candidateUexp, $TargetPackage)
    )
    [IO.File]::WriteAllLines($fileList, $pakLines, [Text.UTF8Encoding]::new($false))
    $pakCreate = Invoke-Captured $pakTool @($pakPath, "-create=$fileList")
    if ($pakCreate.exitCode -ne 0 -or -not (Test-Path -LiteralPath $pakPath -PathType Leaf)) {
        throw "UnrealPak failed to create candidate.`n$($pakCreate.combined)"
    }
    $pakList = Invoke-Captured $pakTool @($pakPath, '-List')
    if ($pakList.exitCode -ne 0) {
        throw "UnrealPak failed to list candidate.`n$($pakList.combined)"
    }
    $listedUasset = $pakList.combined -match [regex]::Escape("$TargetPackage.uasset")
    $listedUexp = $pakList.combined -match [regex]::Escape("$TargetPackage.uexp")

    $status = if ($oldResidue.Count -eq 0 -and $tokenResidue.Count -eq 0 -and
        $binaryEquality -and
        $reopened.FolderName.Value.ToString() -eq $targetFolderName -and
        $reopened.Exports[0].ObjectName.Value.ToString() -eq $targetClassName -and
        $listedUasset -and $listedUexp) { 'candidate-parser-reopen-pak-list' } else { 'blocked-donor-residue' }
    $blockers = [Collections.Generic.List[string]]::new()
    if (-not $binaryEquality) { $blockers.Add('parser reopen VerifyBinaryEquality returned false') }
    if ($oldResidue.Count -gt 0) { $blockers.Add("parser name-map/export/import donor residue: $($oldResidue -join ', ')") }
    if ($tokenResidue.Count -gt 0) { $blockers.Add("binary token donor residue: $($tokenResidue -join ', ')") }
    if (-not $listedUasset -or -not $listedUexp) { $blockers.Add('UnrealPak list did not contain both rewritten sidecars') }
    $blockers.Add('StaticLoadClass, build placement, native F interaction, and replication were not run')

    $report = [ordered]@{
        schema = 'yeet.terminal-cooked-asset-rewrite.v1'
        status = $status
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        tool = [ordered]@{ name = 'UAssetAPI'; assembly = $api; engineVersion = 'VER_UE5_1' }
        donor = [ordered]@{
            uasset = $donor
            uexp = $donorUexp
            packageName = $oldPackageName
            folderName = $oldFolderName
            generatedClass = $oldClassName
            imports = $donorImportNames
            exports = $donorExportNames
            nameMapCount = $nameMap.Count
        }
        rewrite = [ordered]@{
            targetPackage = $TargetPackage
            targetFolderName = $targetFolderName
            targetGeneratedClass = $targetClassName
            candidateUasset = $candidatePath
            candidateUexp = $candidateUexp
            json = $jsonPath
            parserReopen = [ordered]@{
                folderName = $reopened.FolderName.Value.ToString()
                generatedClass = $reopened.Exports[0].ObjectName.Value.ToString()
                binaryEquality = $binaryEquality
                imports = $importNames
                exports = $exportNames
                targetNames = $targetNames
                donorResidue = $oldResidue
            }
            tokenScanDonorResidue = @($tokenResidue)
        }
        pak = [ordered]@{
            path = $pakPath
            fileList = $fileList
            listedUasset = $listedUasset
            listedUexp = $listedUexp
            listOutput = $pakList.combined
        }
        blockers = @($blockers)
        cleanup = 'All candidate binaries and parser JSON are in this unique Temp staging directory; remove it manually after review.'
    }
    $reportPath = Join-Path $staging 'rewrite-result.json'
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
    $report | ConvertTo-Json -Depth 12
    Write-Output "REPORT=$reportPath"
    Write-Output "STAGING=$staging"
}
catch {
    Write-Error ("rewrite-blocked: " + $_.Exception.ToString())
    Write-Output "STAGING=$staging"
    throw
}
