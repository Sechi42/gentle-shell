# PS5.1 public-protocol regression; only GUID-owned disposable files, no registry.
param(
    [ValidateSet('protocol', 'bounds', 'legacy-bounds', 'deadline')][string]$Mode = 'protocol',
    [string]$HelperPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$watch = [Diagnostics.Stopwatch]::StartNew()
# Short GUID component keeps maximum validated record names below MAX_PATH.
# Collision is an error, never permission to reuse an existing directory.
$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N').Substring(0, 4))
$files = [Collections.Generic.List[string]]::new()
$process = $null
$rootOwned = $false
$passed = $false
$failure = $null
$sequence = 0
$payloadBytes = 0
$legacyTrace = [Text.StringBuilder]::new()
$maximumIds = $Mode -in @('bounds', 'legacy-bounds')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Wait-Task($task) {
    $remaining = 23000 - [int]$watch.ElapsedMilliseconds
    Assert ($remaining -gt 0 -and $task.Wait([Math]::Min(5000, $remaining))) 'bounded wait expired'
}
function Canonical($value) {
    if ($null -eq $value) { return 'null' }
    if ($value -is [string] -or $value -is [ValueType]) { return ($value | ConvertTo-Json -Compress) }
    if ($value -is [array]) { return '[' + (($value | ForEach-Object { Canonical $_ }) -join ',') + ']' }
    return '{' + (($value.PSObject.Properties | Sort-Object Name | ForEach-Object { '"' + $_.Name + '":' + (Canonical $_.Value) }) -join ',') + '}'
}
function Request([string]$operation, [hashtable]$fields = @{}) {
    $script:sequence++
    $id = 'r' + $sequence
    if ($maximumIds) { $id = $id.PadRight(128, 'x') }
    $request = @{ requestId = $id; operation = $operation }
    foreach ($key in $fields.Keys) { $request[$key] = $fields[$key] }
    Wait-Task ($process.StandardInput.WriteLineAsync(($request | ConvertTo-Json -Compress -Depth 4)))
    for ($event = 0; $event -lt 3; $event++) {
        $task = $process.StandardOutput.ReadLineAsync(); Wait-Task $task
        Assert ($null -ne $task.Result) 'unexpected EOF'
        if ($operation -eq 'list-page') {
            Assert ([Text.Encoding]::UTF8.GetByteCount($task.Result) -le 16384) 'oversized page frame'
        }
        $reply = $task.Result | ConvertFrom-Json
        if ($null -ne $reply.PSObject.Properties['event']) {
            Assert ($reply.event -ceq 'startup-marker') 'unexpected event'; continue
        }
        Assert ($reply.requestId -ceq $id) 'wrong requestId'
        $keys = @($reply.PSObject.Properties.Name | Sort-Object) -join ','
        Assert ($keys -ceq $(if ($reply.ok) { 'ok,requestId,result' } else { 'error,ok,requestId' })) 'reply schema'
        if ($Mode -eq 'legacy-bounds') {
            [void]$legacyTrace.Append([regex]::Replace((Canonical $reply), '[0-9a-f]{32}', '<token>'))
        }
        return $reply
    }
    throw 'missing reply'
}
function Add-Record([int]$index, [long]$createdAt = 0, [string]$session = '') {
    if ($session -eq '') { $session = 'peer-' + $index.ToString('D4') }
    $token = $index.ToString('x32')
    $text = '{"version":1,"sessionId":"' + $session + '","endpoint":"\\\\.\\pipe\\gentle-pi-' + $token + '","createdAt":' + $createdAt + '}'
    $path = Join-Path $presence ($session + '.' + $token + '.json')
    Assert ($path.Length -lt 260) 'prospective maximum-ID path exceeds MAX_PATH'
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false); $security.SetOwner($sid)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
    $files.Add($path)
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text); $stream.Write($bytes, 0, $bytes.Length); $script:payloadBytes += $bytes.Length } finally { $stream.Dispose() }
}
function File-State {
    return (([IO.Directory]::GetFiles($presence) | Sort-Object | ForEach-Object {
        $info = [IO.FileInfo]::new($_)
        $_ + ':' + $info.Length + ':' + $info.LastWriteTimeUtc.Ticks
    }) -join '|')
}
function Rejected([hashtable]$fields, [string]$errorCode) {
    $before = File-State
    $counter = $files.Count
    $reply = Request 'list-page' $fields
    Assert (-not $reply.ok -and $reply.error -ceq $errorCode) ('expected ' + $errorCode)
    Assert ((File-State) -ceq $before -and $files.Count -eq $counter) 'rejection changed fixture files/counter'
}
function Collect($first) {
    $all = @(); $reply = $first
    do {
        Assert $reply.ok ('page rejected at request ' + $sequence + ': ' + ($reply | ConvertTo-Json -Compress))
        Assert ((@($reply.result.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'cursor,records') 'page schema'
        $all += @($reply.result.records)
        $cursor = $reply.result.cursor
        if ($null -ne $cursor) { $reply = Request 'list-page' @{ cursor = $cursor } }
    } while ($null -ne $cursor)
    return ,$all
}
try {
    Assert ($PSVersionTable.PSVersion.ToString().StartsWith('5.1.')) 'requires PS5.1'
    Assert (-not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'temporary root collision'
    [void][IO.Directory]::CreateDirectory($root)
    $rootOwned = $true
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'gentle-agents'))
    $presence = Join-Path $root 'gentle-agents\transport\presence'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $helper = Join-Path ([IO.Directory]::GetParent($PSScriptRoot).FullName) 'runtime\windows-session-transport.ps1'
    if ($HelperPath -ne '') { $helper = $HelperPath }
    if ($Mode -eq 'deadline') {
        # Controlled source copy only: inject one exact-threshold clock observation.
        # No production testing RPC, changed ACL, or changed production deadline.
        $source = [IO.File]::ReadAllText($helper)
        $needle = 'clock.ElapsedMilliseconds >= ScanMilliseconds'
        Assert (([regex]::Matches($source, [regex]::Escape($needle))).Count -eq 1) 'deadline seam changed'
        $source = $source.Replace('static void CheckScanDeadline(', 'static int DeadlineFixtureChecks; static void CheckScanDeadline(')
        $source = $source.Replace($needle, '(Interlocked.Increment(ref DeadlineFixtureChecks) == 20 ? ScanMilliseconds : clock.ElapsedMilliseconds) >= ScanMilliseconds')
        $scratch = Join-Path ([IO.Directory]::GetParent($PSScriptRoot).FullName) ('node_modules\.gentle-pagination-deadline-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scratch)
        $helper = Join-Path $scratch 'helper.ps1'
        [IO.File]::WriteAllText($helper, $source)
    }
    $info.Arguments = '-NoProfile -NonInteractive -File "' + $helper + '"'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    Assert ($process.Start()) 'launch failed'
    $stderr = $process.StandardError.ReadToEndAsync()
    Assert (Request 'initialize' @{ agentHome = $root }).ok 'initialize failed'
    if ($Mode -eq 'deadline') {
        for ($i = 1; $i -le 65; $i++) { Add-Record $i }
        Rejected @{ cursor = $null } 'busy'
        $a = Request 'list-page' @{ cursor = $null }; $b = Request 'list-page' @{ cursor = $null }
        Assert ($a.ok -and $b.ok) 'deadline failure leaked snapshot capacity'
        Assert ((Collect $a).Count -eq 65 -and (Collect $b).Count -eq 65) 'deadline recovery incomplete'
    } elseif ($maximumIds) {
        for ($i = 1; $i -le 64; $i++) { Add-Record $i 9007199254740991 (('x' * 124) + $i.ToString('D4')) }
        $legacy = Request 'list'
        Assert ($legacy.ok -and @($legacy.result.records).Count -eq 64) 'maximum-input legacy list changed'
        $resolved = Request 'resolve' @{ sessionId = (('x' * 124) + '0064') }
        Assert ($resolved.ok -and $resolved.result.createdAt -eq 9007199254740991) 'maximum-input resolve'
        if ($Mode -eq 'legacy-bounds') {
            $session = ('x' * 124) + '0064'
            Assert (Request 'start').ok 'legacy start'
            Assert ((Request 'enumerate').result.entries -eq 64) 'legacy enumerate'
            $record = Request 'record' @{ sessionId = $session; createdAt = 9007199254740991 }
            Assert ($record.ok -and $record.result.sessionId -ceq $session) 'legacy maximum record'
            Assert (Request 'publish' @{ record = $record.result }).ok 'legacy maximum publish'
            Assert (Request 'remove' @{ record = $record.result }).ok 'legacy maximum remove'
            $listener = Request 'listen' @{ sessionId = $session; createdAt = 9007199254740991 }
            Assert $listener.ok 'legacy maximum listen'
            $ack = Request 'ack' @{ connectionId = ('a' * 128); generation = 2147483647; id = ('a' * 128); accepted = $false }
            Assert $ack.ok 'legacy maximum ack'
            Assert (Request 'stop-listener' @{ record = $listener.result }).ok 'legacy maximum stop'
        }
        if ($Mode -eq 'bounds') {
            $pages = Collect (Request 'list-page' @{ cursor = $null })
            Assert ($pages.Count -eq 64 -and $pages[-1].sessionId.Length -eq 128) 'maximum-input pages'
            # Exact canonical byte count crosses the snapshot bound below 4096 names.
            $i = 65
            while ($payloadBytes -le 524288) {
                Assert ($i -lt 4096) 'byte fixture hit scan cap first'
                Add-Record $i 9007199254740991 (('x' * 124) + $i.ToString('D4')); $i++
            }
            $last = $files[$files.Count - 1]
            [IO.File]::Delete($last); $files.RemoveAt($files.Count - 1)
            $under = Collect (Request 'list-page' @{ cursor = $null })
            Assert ($under.Count -eq $files.Count) 'below-byte-bound snapshot incomplete'
            Add-Record ($i - 1) 9007199254740991 (('x' * 124) + ($i - 1).ToString('D4'))
            Rejected @{ cursor = $null } 'busy'
            # Retry only after changing the fixture; two starts prove no leaked slot.
            for ($index = $files.Count - 1; $index -ge 64; $index--) { [IO.File]::Delete($files[$index]); $files.RemoveAt($index) }
            $a = Request 'list-page' @{ cursor = $null }; $b = Request 'list-page' @{ cursor = $null }
            Assert ($a.ok -and $b.ok) 'byte failure leaked snapshot capacity'
            [void](Collect $a); [void](Collect $b)
        }
    } else {
    for ($i = 1; $i -le 64; $i++) { Add-Record $i }
    $legacy = Request 'list'; Assert ($legacy.ok -and @($legacy.result.records).Count -eq 64) 'legacy64'
    $small = Collect (Request 'list-page' @{ cursor = $null })
    Assert ($small.Count -eq 64) 'page64'
    Add-Record 65
    $all = Collect (Request 'list-page' @{ cursor = $null })
    Assert ($all.Count -eq 65) 'page65'
    for ($i = 66; $i -le 90; $i++) { Add-Record $i }
    Add-Record 100 1 'peer-0090'
    Add-Record 101 1 'peer-0090'
    $first = Request 'list-page' @{ cursor = $null }
    Assert ($first.ok -and $null -ne $first.result.cursor) 'page90 start'
    $used = $first.result.cursor
    Add-Record 91
    $tail = Request 'list-page' @{ cursor = $used }
    Rejected @{ cursor = $used } 'invalid'
    $remaining = Collect $tail
    $stable = @($first.result.records) + $remaining
    Assert ($stable.Count -eq 90 -and $stable[-1].sessionId -ceq 'peer-0090') 'snapshot changed'
    Assert ($stable[-1].endpoint.EndsWith((101).ToString('x32'))) 'dedup tie winner'
    $fresh = Collect (Request 'list-page' @{ cursor = $null })
    Assert ($fresh.Count -eq 91) 'fresh snapshot missing mutation'
    $resolved = Request 'resolve' @{ sessionId = 'peer-0090' }
    Assert ($resolved.ok -and $resolved.result.endpoint.EndsWith((101).ToString('x32'))) 'resolve beyond page1'
    $legacy = Request 'list'; Assert (-not $legacy.ok -and $legacy.error -ceq 'busy') 'legacy overflow'
    Rejected @{ cursor = 'not-a-cursor' } 'invalid'
    Rejected @{ cursor = ('f' * 32) } 'invalid'
    $expiring = Request 'list-page' @{ cursor = $null }
    Start-Sleep -Milliseconds 2100
    Rejected @{ cursor = $expiring.result.cursor } 'invalid'
    $a = Request 'list-page' @{ cursor = $null }; $b = Request 'list-page' @{ cursor = $null }
    Rejected @{ cursor = $null } 'busy'
    [void](Collect $a); [void](Collect $b)
    # Count all names, even invalid records: exhaustion must not return a partial snapshot.
    $validCount = $files.Count
    for ($i = $files.Count; $i -le 4096; $i++) {
        $path = Join-Path $presence ('invalid-' + $i)
        [IO.File]::WriteAllText($path, ''); $files.Add($path)
    }
    Rejected @{ cursor = $null } 'busy'
    for ($index = $files.Count - 1; $index -ge $validCount; $index--) { [IO.File]::Delete($files[$index]); $files.RemoveAt($index) }
    $a = Request 'list-page' @{ cursor = $null }; $b = Request 'list-page' @{ cursor = $null }
    Assert ($a.ok -and $b.ok) 'scan failure leaked snapshot capacity'
    [void](Collect $a); [void](Collect $b)
    }
    $reply = Request 'shutdown'; Assert ($reply.ok -and $reply.result.state -ceq 'partial') 'shutdown'
    Rejected @{ cursor = $null; record = @{ version = 1 } } 'invalid'
    $passed = $true
} catch { $failure = $_.Exception.Message }
finally {
    if ($null -ne $process) {
        $process.StandardInput.Close()
        Assert ($process.WaitForExit(3000)) 'helper did not exit'
        Wait-Task $stderr
        [Console]::Out.WriteLine(('helperExit={0}; stderr={1}' -f $process.ExitCode, $stderr.Result))
        if ($process.ExitCode -ne 0 -or $stderr.Result.Length -ne 0) { $passed = $false }
        $process.Dispose()
    }
    foreach ($path in $files) { [IO.File]::Delete($path) }
    foreach ($relative in @('gentle-agents\transport\presence', 'gentle-agents\transport', 'gentle-agents', '')) {
        $directory = if ($relative -eq '') { $root } else { Join-Path $root $relative }
        if ($rootOwned -and [IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $false) }
    }
}
if (-not $passed) { [Console]::Error.WriteLine($failure); exit 1 }
if ($Mode -eq 'legacy-bounds') {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [Console]::Out.WriteLine([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($legacyTrace.ToString())))) } finally { $hash.Dispose() }
}
[Console]::Out.WriteLine('pagination protocol checks passed; disposable profile removed')
