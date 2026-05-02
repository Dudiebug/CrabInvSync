<#
  CrabInventorySync Bridge — PowerShell HTTP client
  No external dependencies. Requires PowerShell 5+ (built into Windows 10/11).

  Usage (auto-launched by main.lua — do not run manually):
    powershell -File bridge.ps1 <serverUrl> <playerName> <roomPassword> [instanceId]

  Two files talk to the UE4SS Lua mod inside the game:
    Scripts\push_<instanceId>.json  — Lua writes {"room":"...","inventory":{...}}  → bridge POSTs to server
    Scripts\recv_<instanceId>.json  — bridge writes merged inventory               ← server response / poll

  Room code is set via roomCode in config.txt and embedded in push.json by Lua.
  All players who want to sync must use the same roomCode.

  Auto-launch passes instanceId so runtime files are push_<instanceId>.json
  and recv_<instanceId>.json. Manual bridge runs without instanceId still use
  push.json and recv.json for debugging.
#>
param(
    [string]$ServerUrl  = 'https://crab.dudiebug.net',
    [string]$PlayerName = $env:USERNAME,
    [string]$RoomPassword = '4982904',
    # Optional per-launch instance ID passed by main.lua's autolaunch VBS.
    # Empty string means "legacy mode" (used when bridge.ps1 is run manually
    # for debugging) and falls back to the shared push.json / recv.json names.
    [string]$InstanceId = ''
)

$ScriptsDir  = Join-Path $PSScriptRoot 'Scripts'
if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    $PushFile = Join-Path $ScriptsDir 'push.json'
    $RecvFile = Join-Path $ScriptsDir 'recv.json'
} else {
    # Match the filename scheme main.lua uses so the two sides stay in sync
    # when multiple game instances run on one machine.
    $PushFile = Join-Path $ScriptsDir ("push_{0}.json" -f $InstanceId)
    $RecvFile = Join-Path $ScriptsDir ("recv_{0}.json" -f $InstanceId)
}
$LogFilePath = Join-Path $ScriptsDir   'bridge.log'

$lastPushMtime = [datetime]::MinValue
$lastRecvJson  = ''
$currentRoom   = 'default'   # updated from push.json as soon as Lua detects the host
$queuedPushJson  = $null
$queuedPushMtime = [datetime]::MinValue
$RequestTimeoutSec = 6

if ([string]::IsNullOrWhiteSpace($RoomPassword)) {
    $RoomPassword = '4982904'
}

function Ts      { [datetime]::Now.ToString('HH:mm:ss.fff') }
function Log     { param($m) Write-Host "[$( Ts )] $m" }
function LogE    { param($m) Write-Host "[$( Ts )] ERROR $m" -ForegroundColor Red }
function LogFile {
    param($m)
    try {
        [System.IO.File]::AppendAllText($LogFilePath, "[$( Ts )] $m`r`n", (New-Object System.Text.UTF8Encoding $False))
    } catch {}
}

LogFile "=== Bridge started ===  Server=$ServerUrl  Player=$PlayerName"
Log '=== CrabInventorySync Bridge (PowerShell) ==='
Log "Server  : $ServerUrl"
Log "Room    : (from config.txt roomCode, embedded in push.json)"
Log "Player  : $PlayerName"
Log "Push    : $PushFile"
Log "Recv    : $RecvFile"
Log '============================================='
Log 'Leave this window open while playing.'
Log ''

# Write recv.json only when content actually changed.
function WriteRecv {
    param([string]$json, [string]$source)
    if ($json -eq $script:lastRecvJson) { return }
    $script:lastRecvJson = $json
    try {
        [System.IO.File]::WriteAllText($RecvFile, $json, (New-Object System.Text.UTF8Encoding $False))
        $inv = $json | ConvertFrom-Json
        Log "Recv ($source) | weapon=$($inv.weapon) perks=$($inv.perks.Count)"
    } catch {
        LogE "Failed to write recv.json: $_"
    }
}

$gameProcess = 'CrabChampions-Win64-Shipping'
Log "Watching for game process: $gameProcess.exe"
Log 'Starting sync loop...'

$tickCount = 0

while ($true) {

    # ---- Exit if the game has closed (checked every 1 s) ----
    $tickCount++
    if ($tickCount % 2 -eq 0) {
        if (-not (Get-Process -Name $gameProcess -ErrorAction SilentlyContinue)) {
            Log 'Game process not found — sending leave and shutting down.'
            try {
                $leaveBody = (@{ room = $currentRoom; player = $PlayerName; password = $RoomPassword } | ConvertTo-Json -Compress -Depth 8)
                Invoke-RestMethod -Uri "$ServerUrl/leave" -Method POST -Body $leaveBody -ContentType 'application/json' -TimeoutSec $RequestTimeoutSec -ErrorAction SilentlyContinue | Out-Null
                LogFile "LEAVE room=$currentRoom player=$PlayerName"
            } catch {}
            # Clean up per-instance IPC files so stale push_*/recv_* don't
            # accumulate across launches.  Skipped in legacy mode (no InstanceId)
            # because the shared push.json / recv.json might be in use by a
            # manual debugging session.
            if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
                try { if (Test-Path $PushFile) { Remove-Item $PushFile -Force -ErrorAction SilentlyContinue } } catch {}
                try { if (Test-Path $RecvFile) { Remove-Item $RecvFile -Force -ErrorAction SilentlyContinue } } catch {}
            }
            Start-Sleep -Seconds 1
            exit 0
        }
    }

    # ---- Queue push.json when changed; retry queued pushes until one succeeds ----
    if (Test-Path $PushFile) {
        try {
            $info = Get-Item $PushFile -ErrorAction Stop
            if ($info.Length -gt 0 -and $info.LastWriteTime -gt $script:lastPushMtime) {
                $script:queuedPushJson  = [System.IO.File]::ReadAllText($PushFile, [System.Text.Encoding]::UTF8)
                $script:queuedPushMtime = $info.LastWriteTime
            }
        } catch {
            LogE "Failed reading push.json: $_"
        }
    }

    if ($script:queuedPushJson) {
        try {
            $pushData = $script:queuedPushJson | ConvertFrom-Json

            # New format: {"room":"...","inventory":{...}}
            # Legacy format (bare inventory object) still supported as fallback.
            if ($pushData.PSObject.Properties['inventory']) {
                $inv = $pushData.inventory
                if ($pushData.room) {
                    $currentRoom = [string]$pushData.room
                    Log "Room updated: $currentRoom"
                }
            } else {
                $inv = $pushData
            }

            if ($pushData.PSObject.Properties['password'] -and -not [string]::IsNullOrWhiteSpace([string]$pushData.password)) {
                $RoomPassword = [string]$pushData.password
            }

            $players = if ($pushData.PSObject.Properties['players']) { $pushData.players } else { @($PlayerName) }

            $bodyObj = [ordered]@{
                room      = $currentRoom
                player    = $PlayerName
                password  = $RoomPassword
                players   = $players
                inventory = $inv
            }
            # Forward session ID and client logs if present in push.json
            if ($pushData.PSObject.Properties['session'])          { $bodyObj['session']          = $pushData.session }
            if ($pushData.PSObject.Properties['logs'])             { $bodyObj['logs']             = $pushData.logs }
            if ($pushData.PSObject.Properties['clientInstanceId']) { $bodyObj['clientInstanceId'] = $pushData.clientInstanceId }
            if ($pushData.PSObject.Properties['pushSeq'])          { $bodyObj['pushSeq']          = $pushData.pushSeq }
            $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 8

            LogFile "PUSH  room=$currentRoom  player=$PlayerName  body=$bodyJson"

            $resp = Invoke-RestMethod `
                -Uri         "$ServerUrl/push" `
                -Method      POST `
                -Body        $bodyJson `
                -ContentType 'application/json' `
                -TimeoutSec  $RequestTimeoutSec `
                -ErrorAction Stop

            if ($resp.inventory) {
                $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 8
                LogFile "RESP  (push) $merged"
                WriteRecv $merged 'push'
            }

            $script:lastPushMtime = $script:queuedPushMtime
            $script:queuedPushJson = $null
            $script:queuedPushMtime = [datetime]::MinValue
            Log "Pushed | weapon=$($inv.weapon) perks=$($inv.perks.Count)"
        } catch {
            if ($_.Exception -and $_.Exception.Message -match 'ConvertFrom-Json') {
                LogE "Push payload JSON parse failed; waiting for next write."
                $script:queuedPushJson = $null
                $script:queuedPushMtime = [datetime]::MinValue
            } else {
                LogE "Push failed (will retry): $_"
            }
        }
    }

    # ---- Heartbeat — fire-and-forget, tells the server we're still alive ----
    try {
        $hbBody = (@{ room = $currentRoom; player = $PlayerName; password = $RoomPassword } | ConvertTo-Json -Compress -Depth 8)
        Invoke-RestMethod -Uri "$ServerUrl/heartbeat" -Method POST -Body $hbBody -ContentType 'application/json' -TimeoutSec $RequestTimeoutSec -ErrorAction Stop | Out-Null
    } catch {}

    # ---- Poll server for any new merged inventory ----
    try {
        $esc  = [Uri]::EscapeDataString($currentRoom)
        $resp = Invoke-RestMethod `
            -Uri         "$ServerUrl/sync/$esc" `
            -Method      GET `
            -TimeoutSec  $RequestTimeoutSec `
            -ErrorAction Stop

        if ($resp.inventory) {
            $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 8
            if ($merged -ne $script:lastRecvJson) {
                LogFile "RESP  (poll) $merged"
            }
            WriteRecv $merged 'poll'
        }
    } catch {
        LogE "Poll failed: $_"
    }

    Start-Sleep -Milliseconds 500
}
