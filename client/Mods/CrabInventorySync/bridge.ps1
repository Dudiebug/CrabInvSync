<#
  CrabInventorySync Bridge — PowerShell HTTP client
  No external dependencies. Requires PowerShell 5+ (built into Windows 10/11).

  Usage (auto-launched by main.lua — do not run manually):
    powershell -File bridge.ps1 <serverUrl> <roomCode> <playerName> <password>

  Two files talk to the UE4SS Lua mod inside the game:
    Scripts\push.json  — Lua writes {"room":"...","inventory":{...}}  → bridge POSTs to server
    Scripts\recv.json  — bridge writes merged inventory               ← server response / poll

  Room code is auto-detected by Lua from GameState.PlayerArray[0] (the session host) and
  embedded in push.json.  The bridge reads it from there so all players in the same Steam
  session share the same room automatically.  $RoomCode is used only as an initial fallback
  until the first push.json arrives.
#>
param(
    [string]$ServerUrl  = 'https://crab.dudiebug.net',
    [string]$PlayerName = $env:USERNAME
)

$ScriptsDir  = Join-Path $PSScriptRoot 'Scripts'
$PushFile    = Join-Path $ScriptsDir   'push.json'
$RecvFile    = Join-Path $ScriptsDir   'recv.json'
$LogFilePath = Join-Path $ScriptsDir   'bridge.log'

$lastPushMtime = [datetime]::MinValue
$lastRecvJson  = ''
$currentRoom   = 'default'   # updated from push.json as soon as Lua detects the host

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
Log "Room    : (auto-detected from session host)"
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
                $leaveBody = (@{ room = $currentRoom; player = $PlayerName } | ConvertTo-Json -Compress)
                Invoke-RestMethod -Uri "$ServerUrl/leave" -Method POST -Body $leaveBody -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
                LogFile "LEAVE room=$currentRoom player=$PlayerName"
            } catch {}
            Start-Sleep -Seconds 1
            exit 0
        }
    }

    # ---- Push push.json if it changed since last read ----
    if (Test-Path $PushFile) {
        try {
            $info = Get-Item $PushFile -ErrorAction Stop
            if ($info.LastWriteTime -gt $script:lastPushMtime -and $info.Length -gt 0) {
                $script:lastPushMtime = $info.LastWriteTime
                $invJson  = [System.IO.File]::ReadAllText($PushFile, [System.Text.Encoding]::UTF8)
                $pushData = $invJson | ConvertFrom-Json

                # New format: {"room":"...","inventory":{...}}
                # Legacy format (bare inventory object) still supported as fallback.
                if ($pushData.PSObject.Properties['inventory']) {
                    $inv = $pushData.inventory
                    if ($pushData.room) {
                        $currentRoom = $pushData.room
                        Log "Room updated: $currentRoom"
                    }
                } else {
                    $inv = $pushData
                }

                $bodyObj = [ordered]@{
                    room      = $currentRoom
                    player    = $PlayerName
                    inventory = $inv
                }
                $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 5

                LogFile "PUSH  room=$currentRoom  player=$PlayerName  body=$bodyJson"

                $resp = Invoke-RestMethod `
                    -Uri         "$ServerUrl/push" `
                    -Method      POST `
                    -Body        $bodyJson `
                    -ContentType 'application/json' `
                    -ErrorAction Stop

                if ($resp.inventory) {
                    $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 5
                    LogFile "RESP  (push) $merged"
                    WriteRecv $merged 'push'
                }
                Log "Pushed | weapon=$($inv.weapon) perks=$($inv.perks.Count)"
            }
        } catch {
            LogE "Push failed: $_"
        }
    }

    # ---- Heartbeat — fire-and-forget, tells the server we're still alive ----
    try {
        $hbBody = (@{ room = $currentRoom; player = $PlayerName } | ConvertTo-Json -Compress)
        Invoke-RestMethod -Uri "$ServerUrl/heartbeat" -Method POST -Body $hbBody -ContentType 'application/json' -ErrorAction Stop | Out-Null
    } catch {}

    # ---- Poll server for any new merged inventory ----
    try {
        $esc  = [Uri]::EscapeDataString($currentRoom)
        $resp = Invoke-RestMethod `
            -Uri         "$ServerUrl/sync/$esc" `
            -Method      GET `
            -ErrorAction Stop

        if ($resp.inventory) {
            $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 5
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
