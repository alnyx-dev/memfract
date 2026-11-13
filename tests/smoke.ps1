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

function Read-ServeResponse($proc) {
    while ($true) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { throw "serve closed stdout" }
        if ($line.Trim().Length -eq 0) { continue }
        try {
            return $line | ConvertFrom-Json
        } catch {
            throw "serve returned non-JSON: $line"
        }
    }
}

function Invoke-Serve($proc, [string]$command) {
    $proc.StandardInput.WriteLine($command)
    $proc.StandardInput.Flush()
    return Read-ServeResponse $proc
}

$session = "smoke-$PID"
$tableFile = Join-Path $env:TEMP "memfract-smoke-$PID.txt"
$snapFile = Join-Path $env:TEMP "memfract-smoke-$PID.zsn"
$sessionFile = Join-Path $env:TEMP "memfract\$session.session"
$fixtureProc = $null
$serveProc = $null

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

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Cli
    $psi.Arguments = 'serve'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $serveProc = [System.Diagnostics.Process]::Start($psi)
    try {
        $ready = Read-ServeResponse $serveProc
        if (-not $ready.ok -or -not $ready.ready -or $ready.version -ne $expectedVersion) {
            throw "serve handshake failed: $($ready | ConvertTo-Json -Compress)"
        }

        $attachedServe = Invoke-Serve $serveProc "attach --pid $($fixtureProc.Id)"
        if (-not $attachedServe.ok -or $attachedServe.pid -ne $fixtureProc.Id) {
            throw "serve attach failed: $($attachedServe | ConvertTo-Json -Compress)"
        }

        $frozen = Invoke-Serve $serveProc "freeze start --addr $addr --value 305419900 --interval 10"
        if (-not $frozen.ok -or -not $frozen.id) {
            throw "freeze start failed: $($frozen | ConvertTo-Json -Compress)"
        }
        $freezeId = $frozen.id
        Start-Sleep -Milliseconds 120

        $freezeList = Invoke-Serve $serveProc "freeze list"
        if (-not $freezeList.ok -or $freezeList.count -ne 1 -or $freezeList.jobs[0].id -ne $freezeId -or
            $freezeList.jobs[0].writes -lt 1 -or -not $freezeList.jobs[0].active) {
            throw "freeze list returned $($freezeList | ConvertTo-Json -Compress)"
        }
        $frozenRead = Invoke-Serve $serveProc "read --addr $addr --type int32"
        if ($frozenRead.value -ne 305419900) {
            throw "background freeze did not keep the value: $($frozenRead.value)"
        }

        $frozenStop = Invoke-Serve $serveProc "freeze stop --id $freezeId"
        if (-not $frozenStop.ok -or $frozenStop.active -or $frozenStop.writes -lt 1) {
            throw "freeze stop returned $($frozenStop | ConvertTo-Json -Compress)"
        }

        $watched = Invoke-Serve $serveProc "watch start --addr $addr --type int32 --interval 10"
        if (-not $watched.ok -or -not $watched.id) {
            throw "watch start failed: $($watched | ConvertTo-Json -Compress)"
        }
        $watchId = $watched.id
        Start-Sleep -Milliseconds 80
        $null = Invoke-Serve $serveProc "write --addr $addr --value 305419901 --type int32"
        Start-Sleep -Milliseconds 80

        $polled = Invoke-Serve $serveProc "watch poll --id $watchId"
        if (-not $polled.ok -or -not ($polled.samples.value -contains 305419901)) {
            throw "watch poll did not see the change: $($polled | ConvertTo-Json -Compress)"
        }
        $watchStop = Invoke-Serve $serveProc "watch stop --id $watchId"
        if (-not $watchStop.ok -or -not $watchStop.stopped) {
            throw "watch stop returned $($watchStop | ConvertTo-Json -Compress)"
        }

        $bye = Invoke-Serve $serveProc "exit"
        if (-not $bye.ok -or -not $bye.bye) {
            throw "serve exit returned $($bye | ConvertTo-Json -Compress)"
        }
        if (-not $serveProc.WaitForExit(5000)) { throw "serve did not exit" }
    } finally {
        if ($serveProc -and -not $serveProc.HasExited) {
            $serveProc.Kill()
            $serveProc.WaitForExit()
        }
    }

    $oneshot = & $Cli freeze start --addr $addr --value 1 --session $session
    $oneshotCode = $LASTEXITCODE
    if ($oneshotCode -ne 2 -or ($oneshot -join ' ') -notmatch 'ServeOnly') {
        throw "one-shot freeze start should fail with ServeOnly, got $oneshotCode`: $oneshot"
    }

    $detached = Invoke-Cli detach --session $session
    if (-not $detached.detached) { throw "detach failed" }

    Write-Host 'SMOKE OK'
} finally {
    if ($fixtureProc -and -not $fixtureProc.HasExited) {
        Stop-Process -Id $fixtureProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $sessionFile, "$sessionFile.undo", $tableFile, $snapFile -ErrorAction SilentlyContinue
}
