param(
    [Parameter(Mandatory = $true)][string]$Cli,
    [Parameter(Mandatory = $true)][string]$Fixture,
    [Parameter(Mandatory = $true)][string]$VersionFile
)

$ErrorActionPreference = 'Stop'

$versionMatch = [regex]::Match((Get-Content -Raw $VersionFile), 'pub const string = "([^"]+)"')
if (-not $versionMatch.Success) { throw "cannot read the version from $VersionFile" }
$expectedVersion = $versionMatch.Groups[1].Value

function Invoke-Cli {
    $out = & $Cli @args
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "memfract $($args -join ' ') exited with code $code`: $out"
    }
    try {
        return $out | ConvertFrom-Json
    } catch {
        throw "memfract returned non-JSON: $out"
    }
}

$session = "smoke-$PID"
$tableFile = Join-Path $env:TEMP "memfract-smoke-$PID.txt"
$snapFile = Join-Path $env:TEMP "memfract-smoke-$PID.zsn"
$sessionFile = Join-Path $env:TEMP "memfract\$session.session"
$fixtureProc = $null

try {
    $info = Invoke-Cli version
    if ($info.version -ne $expectedVersion) {
        throw "unexpected version: $($info.version), expected $expectedVersion"
    }

    $fixtureProc = Start-Process -FilePath $Fixture -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 400

    $attached = Invoke-Cli attach --pid $fixtureProc.Id --session $session
    if (-not $attached.attached -or $attached.pid -ne $fixtureProc.Id) {
        throw "attach failed: $($attached | ConvertTo-Json -Compress)"
    }

    $scan = Invoke-Cli scan first --type int32 --value 305419896 --session $session
    if ($scan.count -lt 1) { throw "first scan found nothing" }
    if ($scan.regions_scanned -lt 1 -or $scan.bytes_read -lt 1) {
        throw "scan response is missing regions_scanned or bytes_read: $($scan | ConvertTo-Json -Compress)"
    }

    $scan1 = Invoke-Cli scan first --type int32 --value 305419896 --threads 1 --session $session
    if ($scan1.count -ne $scan.count) {
        throw "single-threaded scan found $($scan1.count) addresses, multi-threaded found $($scan.count)"
    }

    $list = Invoke-Cli scan list --session $session
    $addr = $list.results[0].address
    if ($list.results[0].value -ne 305419896) {
        throw "unexpected value after scan: $($list.results[0].value)"
    }

    $null = Invoke-Cli table add --from-scan 0 --desc smoke --session $session
    $written = Invoke-Cli table write --index 0 --value 305419897 --session $session
    if ($written.value -ne 305419897) { throw "table write did not confirm the value" }

    $read = Invoke-Cli read --addr $addr --type int32 --session $session
    if ($read.value -ne 305419897) { throw "read returned $($read.value), expected 305419897" }

    $delta = Invoke-Cli scan next --cond delta --value 1 --session $session
    if ($delta.count -ne 1) { throw "delta filter left $($delta.count) addresses instead of 1" }

    $snap = Invoke-Cli scan snapshot save --file $snapFile --session $session
    if ($snap.count -ne 1 -or $snap.type -ne 'int32') {
        throw "snapshot save returned $($snap | ConvertTo-Json -Compress)"
    }

    $next = Invoke-Cli scan next --cond exact --value 305419897 --session $session
    if ($next.count -ne 1) { throw "scan next left $($next.count) addresses instead of 1" }

    $null = Invoke-Cli table save --file $tableFile --session $session
    $null = Invoke-Cli table clear --session $session
    $loaded = Invoke-Cli table load --file $tableFile --session $session
    if ($loaded.rows -ne 1) { throw "table load loaded $($loaded.rows) rows instead of 1" }

    $rows = Invoke-Cli table list --session $session
    if ($rows.count -ne 1) { throw "table list returned $($rows.count) rows" }

    $strScan = Invoke-Cli scan first --type string --value memfract-needle --module fixture.exe --session $session
    if ($strScan.count -lt 1) { throw "string scan found nothing" }
    $strList = Invoke-Cli scan list --limit 10000 --session $session
    if (-not ($strList.results.value -contains 'memfract-needle')) {
        throw "string scan did not return the fixture string"
    }

    $sigScan = Invoke-Cli scan first --type bytes --value '48 8B ?? ?? 89' --module fixture.exe --session $session
    if ($sigScan.count -lt 1) { throw "byte-pattern scan found nothing" }
    $sigList = Invoke-Cli scan list --limit 10000 --session $session
    if (-not ($sigList.results.value -contains '48 8b 90 12 89')) {
        throw "byte-pattern scan did not return the fixture signature"
    }

    $sigNext = Invoke-Cli scan next --cond unchanged --session $session
    if ($sigNext.count -lt 1) { throw "unchanged filter dropped every byte-pattern match" }

    $reloaded = Invoke-Cli scan snapshot load --file $snapFile --session $session
    if ($reloaded.count -ne 1 -or $reloaded.type -ne 'int32') {
        throw "snapshot load returned $($reloaded | ConvertTo-Json -Compress)"
    }
    $status = Invoke-Cli scan status --session $session
    if (-not $status.can_undo) { throw "snapshot load did not keep an undo step" }

    $undone = Invoke-Cli scan undo --session $session
    if (-not $undone.undone -or $undone.count -ne $sigNext.count) {
        throw "undo returned $($undone | ConvertTo-Json -Compress), expected $($sigNext.count) addresses"
    }
    $status = Invoke-Cli scan status --session $session
    if ($status.can_undo) { throw "undo history was not consumed" }

    $detached = Invoke-Cli detach --session $session
    if (-not $detached.detached) { throw "detach failed" }

    Write-Host 'SMOKE OK'
} finally {
    if ($fixtureProc -and -not $fixtureProc.HasExited) {
        Stop-Process -Id $fixtureProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $sessionFile, "$sessionFile.undo", $tableFile, $snapFile -ErrorAction SilentlyContinue
}
