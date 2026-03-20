<#
  CrabInventorySync v0.0.1 — PowerShell HTTP Bridge
  No external dependencies. Requires PowerShell 5+ (built into Windows 10/11).

  Usage (auto-launched by main.lua — do not run manually):
    powershell -File bridge.ps1 <serverUrl> <playerName>

  IPC files (inside Scripts/ subdirectory):
    push.json  — Lua writes { peers: [...], inventory: {...} }  → bridge POSTs to /push
    recv.json  — bridge writes merged inventory                 ← server response / poll
#>
param(
    [string]$ServerUrl  = 'https://crab.dudiebug.net',
    [string]$PlayerName = $env:USERNAME
)

$ScriptsDir  = Join-Path $PSScriptRoot 'Scripts'
$PushFile    = Join-Path $ScriptsDir   'push.json'
$RecvFile    = Join-Path $ScriptsDir   'recv.json'
$LogFile     = Join-Path $ScriptsDir   'bridge.log'

$lastPushMtime = [datetime]::MinValue
$lastRecvJson  = ''
$tick          = 0

function Ts   { [datetime]::Now.ToString('HH:mm:ss.fff') }
function Log  { param($m) Write-Host "[$( Ts )] $m" }
function LogE { param($m) Write-Host "[$( Ts )] ERROR $m" -ForegroundColor Red }
function LogF {
    param($m)
    try { [IO.File]::AppendAllText($LogFile, "[$( Ts )] $m`r`n", (New-Object Text.UTF8Encoding $false)) } catch {}
}

function WriteRecv {
    param([string]$json, [string]$source)
    if ($json -eq $script:lastRecvJson) { return }
    $script:lastRecvJson = $json
    try {
        [IO.File]::WriteAllText($RecvFile, $json, (New-Object Text.UTF8Encoding $false))
        Log "recv ($source) updated"
    } catch {
        LogE "recv write failed: $_"
    }
}

LogF "=== Bridge started === Server=$ServerUrl Player=$PlayerName"
Log  '=== CrabInventorySync v0.0.1 Bridge ==='
Log  "Server : $ServerUrl"
Log  "Player : $PlayerName"
Log  "Push   : $PushFile"
Log  "Recv   : $RecvFile"
Log  '========================================='
Log  'Leave this window open while playing.'
Log  ''

$gameProc = 'CrabChampions-Win64-Shipping'
Log "Watching for game process: $gameProc.exe"

while ($true) {
    $tick++

    # ---- Exit if game closed (every 2 s = 4 ticks) ----
    if ($tick % 4 -eq 0) {
        if (-not (Get-Process -Name $gameProc -ErrorAction SilentlyContinue)) {
            Log 'Game closed — sending leave and exiting.'
            try {
                $body = (@{ player = $PlayerName } | ConvertTo-Json -Compress)
                Invoke-RestMethod -Uri "$ServerUrl/leave" -Method POST -Body $body -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
                LogF "LEAVE player=$PlayerName"
            } catch {}
            Start-Sleep -Seconds 1
            exit 0
        }
    }

    # ---- Push if push.json changed ----
    if (Test-Path $PushFile) {
        try {
            $info = Get-Item $PushFile -ErrorAction Stop
            if ($info.LastWriteTime -gt $script:lastPushMtime -and $info.Length -gt 0) {
                $script:lastPushMtime = $info.LastWriteTime
                $raw = [IO.File]::ReadAllText($PushFile, [Text.Encoding]::UTF8)
                $parsed = $raw | ConvertFrom-Json

                $peers = @()
                if ($parsed.PSObject.Properties['inventory']) {
                    $inv   = $parsed.inventory
                    $peers = if ($parsed.peers) { $parsed.peers } else { @() }
                } else {
                    $inv = $parsed
                }

                $bodyObj = [ordered]@{
                    player    = $PlayerName
                    peers     = $peers
                    inventory = $inv
                }
                $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 5
                LogF "PUSH player=$PlayerName peers=$($peers -join ',') body=$bodyJson"

                $resp = Invoke-RestMethod `
                    -Uri "$ServerUrl/push" `
                    -Method POST `
                    -Body $bodyJson `
                    -ContentType 'application/json' `
                    -ErrorAction Stop

                if ($resp.inventory) {
                    $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 5
                    LogF "RESP (push) $merged"
                    WriteRecv $merged 'push'
                }
                Log "Pushed | W=$($inv.weapon) A=$($inv.ability)"
            }
        } catch {
            LogE "Push failed: $_"
        }
    }

    # ---- Heartbeat (every 10 s = 20 ticks) ----
    if ($tick % 20 -eq 0) {
        try {
            $hb = (@{ player = $PlayerName } | ConvertTo-Json -Compress)
            Invoke-RestMethod -Uri "$ServerUrl/heartbeat" -Method POST -Body $hb -ContentType 'application/json' -ErrorAction Stop | Out-Null
        } catch {}
    }

    # ---- Fallback poll (every 4 s = 8 ticks) ----
    if ($tick % 8 -eq 0) {
        try {
            $esc  = [Uri]::EscapeDataString($PlayerName)
            $resp = Invoke-RestMethod -Uri "$ServerUrl/sync/$esc" -Method GET -ErrorAction Stop
            if ($resp.inventory) {
                $merged = $resp.inventory | ConvertTo-Json -Compress -Depth 5
                if ($merged -ne $script:lastRecvJson) {
                    LogF "RESP (poll) $merged"
                }
                WriteRecv $merged 'poll'
            }
        } catch {
            LogE "Poll failed: $_"
        }
    }

    Start-Sleep -Milliseconds 500
}
