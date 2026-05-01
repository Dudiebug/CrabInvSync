param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'

function Resolve-CrabSyncInstallRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path (Get-Location) $Path
    }
    $full = [System.IO.Path]::GetFullPath($candidate)
    $leaf = Split-Path -Leaf $full

    if ($leaf -ieq 'CrabInventorySync') {
        return $full
    }
    if ($leaf -ieq 'Mods') {
        return (Join-Path $full 'CrabInventorySync')
    }

    $directMods = Join-Path $full 'Mods'
    $ue4ssMods = Join-Path (Join-Path $full 'ue4ss') 'Mods'
    if (Test-Path -LiteralPath $directMods) {
        return (Join-Path $directMods 'CrabInventorySync')
    }
    if (Test-Path -LiteralPath $ue4ssMods) {
        return (Join-Path $ue4ssMods 'CrabInventorySync')
    }
    return (Join-Path $directMods 'CrabInventorySync')
}

function Assert-ContainsPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)) {
        throw "$Label not found in $Path"
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repoRoot 'client\Mods\CrabInventorySync'
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "Source client folder not found: $sourceRoot"
}

$installRoot = Resolve-CrabSyncInstallRoot $Destination
$files = @(
    'bridge.ps1',
    'enabled.txt',
    'package.json',
    'Scripts\config.txt',
    'Scripts\debug_helpers.lua',
    'Scripts\debug_perks.lua',
    'Scripts\main.lua'
)

foreach ($relative in $files) {
    $src = Join-Path $sourceRoot $relative
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Required source file missing: $src"
    }
    $dst = Join-Path $installRoot $relative
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

$installedMain = Join-Path $installRoot 'Scripts\main.lua'
$installedBridge = Join-Path $installRoot 'bridge.ps1'
$installedConfig = Join-Path $installRoot 'Scripts\config.txt'

Assert-ContainsPattern $installedMain 'healthValid' 'healthValid support'
Assert-ContainsPattern $installedMain 'INSTANCE_ID' 'INSTANCE_ID support'
Assert-ContainsPattern $installedMain 'push_' 'per-instance push file support'
Assert-ContainsPattern $installedMain 'recv_' 'per-instance recv file support'
Assert-ContainsPattern $installedBridge '\$InstanceId' 'bridge InstanceId parameter'
Assert-ContainsPattern $installedBridge 'ConvertTo-Json -Compress -Depth 8' 'bridge JSON depth 8'

if (Select-String -LiteralPath $installedConfig -Pattern 'healthProperty' -Quiet) {
    throw "Stale healthProperty key found in installed config: $installedConfig"
}

$mainInfo = Get-Item -LiteralPath $installedMain
Write-Host "Installed CrabInventorySync to: $installRoot"
Write-Host ("Installed main.lua timestamp: {0:yyyy-MM-dd HH:mm:ss}" -f $mainInfo.LastWriteTime)
Write-Host "Confirmed patterns: healthValid, INSTANCE_ID, push_, recv_, bridge InstanceId, Depth 8."
Write-Host "No files outside the CrabInventorySync mod folder were deleted or mirrored."
