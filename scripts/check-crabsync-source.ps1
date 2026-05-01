param(
    [string]$Root = (Join-Path $PSScriptRoot '..')
)

$target = Join-Path $Root 'client\Mods\CrabInventorySync'
if (-not (Test-Path $target)) {
    Write-Error "CrabInventorySync source folder not found: $target"
    exit 1
}

$terms = @(
    ('perk_' + 'tasty' + 'orange' + '_mod'),
    ('Tasty' + 'Orange'),
    ('Tasty' + 'Mod'),
    ('Crab' + 'Tasty' + 'Mod'),
    ('Collector' + ' host')
)

$matches = New-Object System.Collections.Generic.List[string]
$files = Get-ChildItem -LiteralPath $target -Recurse -File -Include *.lua,*.ps1,*.txt,*.json,*.md,*.js

foreach ($file in $files) {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        foreach ($term in $terms) {
            if ($line.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matches.Add(('{0}:{1}: stale split-out mod reference "{2}"' -f $file.FullName, $lineNo, $term))
            }
        }
    }
}

if ($matches.Count -gt 0) {
    $matches | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "CrabInventorySync source guard passed."
