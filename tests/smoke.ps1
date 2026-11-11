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

    $next = Invoke-Cli scan next --cond exact --value 305419897 --session $session
    if ($next.count -ne 1) { throw "scan next left $($next.count) addresses instead of 1" }

    $null = Invoke-Cli table save --file $tableFile --session $session
    $null = Invoke-Cli table clear --session $session
    $loaded = Invoke-Cli table load --file $tableFile --session $session
    if ($loaded.rows -ne 1) { throw "table load loaded $($loaded.rows) rows instead of 1" }

    $rows = Invoke-Cli table list --session $session
    if ($rows.count -ne 1) { throw "table list returned $($rows.count) rows" }

    $detached = Invoke-Cli detach --session $session
    if (-not $detached.detached) { throw "detach failed" }

    Write-Host 'SMOKE OK'
} finally {
    if ($fixtureProc -and -not $fixtureProc.HasExited) {
        Stop-Process -Id $fixtureProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $sessionFile, $tableFile -ErrorAction SilentlyContinue
}
