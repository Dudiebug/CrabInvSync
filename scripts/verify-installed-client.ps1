param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

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

function Test-Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $script:failures.Add("Missing file for ${Label}: $Path")
        return
    }
    if (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet) {
        Write-Host "[OK] $Label"
    } else {
        $script:failures.Add("Missing $Label in $Path")
    }
}

$installRoot = Resolve-CrabSyncInstallRoot $Destination
$scriptsDir = Join-Path $installRoot 'Scripts'
$mainPath = Join-Path $scriptsDir 'main.lua'
$bridgePath = Join-Path $installRoot 'bridge.ps1'
$configPath = Join-Path $scriptsDir 'config.txt'

Write-Host "Verifying CrabInventorySync install: $installRoot"

Test-Pattern $mainPath 'healthValid' 'main.lua healthValid support'
Test-Pattern $mainPath 'INSTANCE_ID' 'main.lua INSTANCE_ID support'
Test-Pattern $mainPath 'push_' 'main.lua push_<instance>.json support'
Test-Pattern $mainPath 'recv_' 'main.lua recv_<instance>.json support'
Test-Pattern $bridgePath '\$InstanceId' 'bridge.ps1 InstanceId parameter'
Test-Pattern $bridgePath 'ConvertTo-Json -Compress -Depth 8' 'bridge.ps1 Depth 8 JSON'

if (Test-Path -LiteralPath $configPath) {
    if (Select-String -LiteralPath $configPath -Pattern 'healthProperty' -Quiet) {
        $failures.Add("Stale healthProperty key found in $configPath")
    } else {
        Write-Host "[OK] config has no healthProperty key"
    }
    $syncHealth = Select-String -LiteralPath $configPath -Pattern '^\s*syncHealth\s*=' | Select-Object -First 1
    if ($syncHealth) {
        Write-Host ("Config {0}" -f $syncHealth.Line.Trim())
    }
} else {
    $failures.Add("Missing config: $configPath")
}

Write-Host "Runtime IPC files in Scripts:"
$runtimeFiles = @()
if (Test-Path -LiteralPath $scriptsDir) {
    $runtimeFiles = Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'push*.json' -or $_.Name -like 'recv*.json' }
}
if ($runtimeFiles.Count -eq 0) {
    Write-Host "  (none)"
} else {
    $runtimeFiles | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0}  {1} bytes  {2:yyyy-MM-dd HH:mm:ss}" -f $_.Name, $_.Length, $_.LastWriteTime)
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("Installed client verification failed:`n" + ($failures -join "`n"))
    exit 1
}

Write-Host "Installed client verification passed."
