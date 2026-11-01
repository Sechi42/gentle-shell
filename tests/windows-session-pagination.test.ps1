# PS5.1 public-protocol regression recovered from 8f3ae84cf99bc31e7a9146cd2153cbe3072437ba.
# Only exclusively owned synthetic child-TMPDIR files/pipes; no registry or real profiles.
param(
    [ValidateSet('protocol', 'bounds', 'legacy-bounds', 'deadline')][string]$Mode = 'protocol',
    [string]$HelperPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native extended-length paths are fixture-local: no OS/.NET-global long-path setting.
# Production reads remain unchanged, relative to the helper's pinned NT directory.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PaginationFixtureIO {
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFileAttributesW(string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateDirectoryW(string path, IntPtr security);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool RemoveDirectoryW(string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool DeleteFileW(string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafePipeHandle CreateNamedPipeW(string name, uint mode, uint pipeMode, uint instances, uint output, uint input, uint timeout, IntPtr security);
    static void Error() { throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static string Extended(string path) { return @"\\?\" + path; }
    // Inspect every existing ancestor without following a reparse point, including TMPDIR.
    public static bool Verify(string path) {
        if (path.Length < 3 || path[1] != ':' || path[2] != '\\') throw new IOException("requires a local absolute path");
        string current = path.Substring(0, 3);
        string[] parts = path.Substring(3).Split('\\');
        for (int i = -1; i < parts.Length; i++) {
            if (i >= 0) {
                if (parts[i].Length == 0 || parts[i] == "." || parts[i] == ".." || parts[i].IndexOfAny(new char[] { ':', '/', '\0' }) >= 0) throw new IOException("unsafe component");
                current = current.TrimEnd('\\') + "\\" + parts[i];
            }
            uint attributes = GetFileAttributesW(Extended(current));
            if (attributes == UInt32.MaxValue) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 3) return false;
                throw new Win32Exception(error);
            }
            if ((attributes & 0x400) != 0 || (i < parts.Length - 1 && (attributes & 0x10) == 0)) throw new IOException("reparse/non-directory ancestor");
        }
        return true;
    }
    static IntPtr Security(byte[] descriptor, out IntPtr bytes) {
        bytes = Marshal.AllocHGlobal(descriptor.Length); Marshal.Copy(descriptor, 0, bytes, descriptor.Length);
        int size = IntPtr.Size == 8 ? 24 : 12; IntPtr attributes = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(attributes, i, 0);
        Marshal.WriteInt32(attributes, size); Marshal.WriteIntPtr(attributes, IntPtr.Size == 8 ? 8 : 4, bytes);
        return attributes;
    }
    public static void CreateDirectory(string path, byte[] descriptor) {
        if (!Verify(path.Substring(0, path.LastIndexOf('\\'))) || Verify(path)) throw new IOException("directory collision/missing parent");
        IntPtr bytes, attributes = Security(descriptor, out bytes);
        try { if (!CreateDirectoryW(Extended(path), attributes)) Error(); }
        finally { Marshal.FreeHGlobal(attributes); Marshal.FreeHGlobal(bytes); }
    }
    public static void WriteNew(string path, byte[] value, byte[] descriptor, List<string> owned) {
        if (!Verify(path.Substring(0, path.LastIndexOf('\\'))) || Verify(path)) throw new IOException("file collision/missing parent");
        IntPtr bytes, attributes = Security(descriptor, out bytes);
        try {
            using (SafeFileHandle handle = CreateFileW(Extended(path), 0x40000000, 0, attributes, 1, 0x00200000, IntPtr.Zero)) {
                if (handle.IsInvalid) Error();
                owned.Add(path); // exact ownership recorded before any fallible write
                using (FileStream stream = new FileStream(handle, FileAccess.Write)) { stream.Write(value, 0, value.Length); }
            }
        } finally { Marshal.FreeHGlobal(attributes); Marshal.FreeHGlobal(bytes); }
    }
    public static string State(string path) {
        if (!Verify(path)) return "missing";
        using (SafeFileHandle handle = CreateFileW(Extended(path), 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) Error(); FileInfo info;
            if (!GetFileInformationByHandle(handle, out info)) Error();
            if ((info.Attributes & 0x400) != 0) throw new IOException("reparse state target");
            return info.SizeHigh + ":" + info.SizeLow + ":" + info.Write.dwHighDateTime + ":" + info.Write.dwLowDateTime;
        }
    }
    public static void DeleteFile(string path) {
        if (Verify(path) && !DeleteFileW(Extended(path))) Error();
    }
    public static void DeleteDirectory(string path) {
        if (Verify(path) && !RemoveDirectoryW(Extended(path))) Error(); // never recursive
    }
    public static NamedPipeServerStream Pipe(string token, byte[] descriptor) {
        IntPtr bytes, attributes = Security(descriptor, out bytes);
        try {
            // FIRST_PIPE_INSTANCE rejects pre-existing endpoints; never connect to one.
            SafePipeHandle handle = CreateNamedPipeW(@"\\.\pipe\gentle-pi-" + token, 0x40080003, 0, 1, 4096, 4096, 0, attributes);
            if (handle.IsInvalid) { handle.Dispose(); Error(); }
            try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
            catch { handle.Dispose(); throw; }
        } finally { Marshal.FreeHGlobal(attributes); Marshal.FreeHGlobal(bytes); }
    }
}
'@
$watch = [Diagnostics.Stopwatch]::StartNew()
$waitWatch = [Diagnostics.Stopwatch]::new()
$phase = 'setup'
$lastOperation = 'none'
$assertionFailure = $null
$files = [Collections.Generic.List[string]]::new()
$directories = [Collections.Generic.List[string]]::new()
$pipes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$process = $null
$started = $false
$root = $null
$scratch = $null
$passed = $false
$failure = $null
$sequence = 0
$payloadBytes = 0
$legacyTrace = [Text.StringBuilder]::new()
$maximumIds = $Mode -in @('bounds', 'legacy-bounds')
function Assert($condition, [string]$message) {
    if (-not $condition) { $script:assertionFailure = $message; throw $message }
}
function Failure-Context($errorRecord) {
    # Only fixed assertion text or an exception type; never native messages/replies/paths.
    $reason = $errorRecord.Exception.GetType().Name
    if ($errorRecord.Exception.Message -ceq $assertionFailure) { $reason = $assertionFailure }
    return ('{0}; phase={1}; operation={2}; sequence={3}; ownedFiles={4}; wallMs={5}; activeWaitMs={6}' -f $reason, $phase, $lastOperation, $sequence, $files.Count, $watch.ElapsedMilliseconds, $waitWatch.ElapsedMilliseconds)
}
function Wait-Task($task) {
    # Completed tasks need no waiting budget, but must still propagate task faults.
    if ($task.IsCompleted) { [void]$task.Wait(0); return }
    $remaining = 23000 - [int]$waitWatch.ElapsedMilliseconds
    Assert ($remaining -gt 0) 'bounded wait expired'
    # Charge only Task.Wait, never owned filesystem work or cursor-expiry sleep.
    $waitWatch.Start()
    try { $completed = $task.Wait([Math]::Min(5000, $remaining)) }
    finally { $waitWatch.Stop() }
    Assert $completed 'bounded wait expired'
}
function Owned-Path([string]$path) {
    Assert ($null -ne $root -and ($path -ceq $root -or $path.StartsWith($root + '\', [StringComparison]::Ordinal))) 'outside owned root'
    return $path
}
function Remove-File([string]$path) {
    $script:phase = 'file-remove'
    Assert ($files.Contains($path)) 'unowned file deletion'
    [PaginationFixtureIO]::DeleteFile((Owned-Path $path))
}
function Write-File([string]$path, [byte[]]$bytes) {
    $script:phase = 'file-create'
    [void](Owned-Path $path)
    # Native CREATE_NEW registers ownership before writing, also on write failure.
    [PaginationFixtureIO]::WriteNew($path, $bytes, $fileDescriptor, $files)
}
function Canonical($value) {
    if ($null -eq $value) { return 'null' }
    if ($value -is [string] -or $value -is [ValueType]) { return ($value | ConvertTo-Json -Compress) }
    if ($value -is [array]) { return '[' + (($value | ForEach-Object { Canonical $_ }) -join ',') + ']' }
    return '{' + (($value.PSObject.Properties | Sort-Object Name | ForEach-Object { '"' + $_.Name + '":' + (Canonical $_.Value) }) -join ',') + '}'
}
function Request([string]$operation, [hashtable]$fields = @{}) {
    $script:sequence++
    $script:lastOperation = $operation
    $script:phase = 'request-write'
    $id = 'r' + $sequence
    if ($maximumIds) { $id = $id.PadRight(128, 'x') }
    $request = @{ requestId = $id; operation = $operation }
    foreach ($key in $fields.Keys) { $request[$key] = $fields[$key] }
    Wait-Task ($process.StandardInput.WriteLineAsync(($request | ConvertTo-Json -Compress -Depth 4)))
    for ($event = 0; $event -lt 3; $event++) {
        $script:phase = 'request-read'
        $task = $process.StandardOutput.ReadLineAsync(); Wait-Task $task
        $script:phase = 'request-validate'
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
    $script:phase = 'record-setup'
    if ($session -eq '') { $session = 'peer-' + $index.ToString('D4') }
    $token = $index.ToString('x32')
    if (-not $pipes.ContainsKey($token)) {
        $pipe = [PaginationFixtureIO]::Pipe($token, $pipeDescriptor)
        $pipes.Add($token, @{ Pipe = $pipe; Accept = $null })
        # Arm native listening synchronously, but never block awaiting a connection.
        # Production WaitNamedPipe only probes; it does not consume this accept.
        $pipes[$token].Accept = $pipe.BeginWaitForConnection($null, $null)
    }
    Assert (-not $pipes[$token].Accept.IsCompleted) 'unexpected synthetic pipe connection'
    $text = '{"version":1,"sessionId":"' + $session + '","endpoint":"\\\\.\\pipe\\gentle-pi-' + $token + '","createdAt":' + $createdAt + '}'
    # Concatenation avoids .NET Framework MAX_PATH checks in Join-Path/GetFullPath.
    $path = $presence + '\' + $session + '.' + $token + '.json'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    Write-File $path $bytes
    $script:payloadBytes += $bytes.Length
}
function File-State {
    $script:phase = 'file-state'
    # All created files plus the directory timestamp: detects removals, writes and
    # new entries without managed MAX_PATH enumeration or recursive traversal.
    return ([PaginationFixtureIO]::State((Owned-Path $presence))) + '|' + (($files | Sort-Object | ForEach-Object {
        $_ + ':' + [PaginationFixtureIO]::State((Owned-Path $_))
    }) -join '|')
}
function Rejected([hashtable]$fields, [string]$errorCode) {
    $before = File-State
    $counter = $files.Count
    $pipeCounter = $pipes.Count
    $reply = Request 'list-page' $fields
    Assert (-not $reply.ok -and $reply.error -ceq $errorCode) ('expected ' + $errorCode)
    Assert ((File-State) -ceq $before -and $files.Count -eq $counter -and $pipes.Count -eq $pipeCounter) 'rejection changed fixture files/counters'
}
function Collect($first) {
    $all = @(); $reply = $first
    do {
        Assert $reply.ok 'page rejected'
        Assert ((@($reply.result.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'cursor,records') 'page schema'
        Assert (@($reply.result.records).Count -le 32) 'page record limit'
        $all += @($reply.result.records)
        $cursor = $reply.result.cursor
        if ($null -ne $cursor) { $reply = Request 'list-page' @{ cursor = $cursor } }
    } while ($null -ne $cursor)
    return ,$all
}
try {
    Assert ($PSVersionTable.PSVersion.ToString().StartsWith('5.1.')) 'requires PS5.1'
    Assert (-not [string]::IsNullOrEmpty($env:TMPDIR)) 'requires dedicated child runtime TMPDIR'
    Assert ($env:TMPDIR -cmatch '^[A-Za-z]:[\\/]') 'TMPDIR must be a native absolute child-runtime path'
    $temp = [IO.Path]::GetFullPath($env:TMPDIR).TrimEnd('\')
    Assert ($temp -cmatch '^[A-Za-z]:\\' -and [PaginationFixtureIO]::Verify($temp)) 'unsafe child TMPDIR'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false); $security.SetOwner($sid)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    $fileDescriptor = $security.GetSecurityDescriptorBinaryForm()
    $directorySecurity = [Security.AccessControl.DirectorySecurity]::new()
    $directorySecurity.SetAccessRuleProtection($true, $false); $directorySecurity.SetOwner($sid)
    $directorySecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    $directoryDescriptor = $directorySecurity.GetSecurityDescriptorBinaryForm()
    $pipeSecurity = [IO.Pipes.PipeSecurity]::new()
    $pipeSecurity.SetAccessRuleProtection($true, $false); $pipeSecurity.SetOwner($sid)
    $pipeSecurity.AddAccessRule([IO.Pipes.PipeAccessRule]::new($sid, 'FullControl', 'Allow'))
    $pipeDescriptor = $pipeSecurity.GetSecurityDescriptorBinaryForm()
    $root = $temp + '\pagination-' + [Guid]::NewGuid().ToString('N')
    Assert ($root.StartsWith($temp + '\', [StringComparison]::Ordinal)) 'temporary containment'
    [PaginationFixtureIO]::CreateDirectory($root, $directoryDescriptor); $directories.Add($root)
    $routing = $root + '\gentle-agents'
    [PaginationFixtureIO]::CreateDirectory($routing, $directoryDescriptor); $directories.Add($routing)
    $transport = $routing + '\transport'
    $presence = $transport + '\presence'
    # Only this child helper may create these previously absent private directories.
    Assert (-not [PaginationFixtureIO]::Verify($transport)) 'transport collision'
    $directories.Add($transport); $directories.Add($presence)
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
        $scratch = $root + '\deadline-' + [Guid]::NewGuid().ToString('N')
        [PaginationFixtureIO]::CreateDirectory($scratch, $directoryDescriptor); $directories.Add($scratch)
        $helper = $scratch + '\helper.ps1'
        Write-File $helper ([Text.UTF8Encoding]::new($false).GetBytes($source))
    }
    $info.Arguments = '-NoProfile -NonInteractive -File "' + $helper + '"'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $phase = 'helper-start'
    $started = $process.Start(); Assert $started 'launch failed'
    $stderr = $process.StandardError.ReadToEndAsync()
    Assert (Request 'initialize' @{ agentHome = $root }).ok 'initialize failed'
    Assert ([PaginationFixtureIO]::Verify($presence)) 'unsafe/missing helper presence directory'
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
            Remove-File $last; $files.RemoveAt($files.Count - 1)
            $under = Collect (Request 'list-page' @{ cursor = $null })
            Assert ($under.Count -eq $files.Count) 'below-byte-bound snapshot incomplete'
            Add-Record ($i - 1) 9007199254740991 (('x' * 124) + ($i - 1).ToString('D4'))
            Rejected @{ cursor = $null } 'busy'
            # Retry only after changing the fixture; two starts prove no leaked slot.
            for ($index = $files.Count - 1; $index -ge 64; $index--) { Remove-File $files[$index]; $files.RemoveAt($index) }
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
        for ($index = 1; $index -lt $stable.Count; $index++) {
            Assert ([StringComparer]::Ordinal.Compare($stable[$index - 1].sessionId, $stable[$index].sessionId) -lt 0) 'non-ordinal snapshot order'
        }
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
            $path = $presence + '\invalid-' + $i
            Write-File $path ([byte[]]@())
        }
        Rejected @{ cursor = $null } 'busy'
        for ($index = $files.Count - 1; $index -ge $validCount; $index--) { Remove-File $files[$index]; $files.RemoveAt($index) }
        $a = Request 'list-page' @{ cursor = $null }; $b = Request 'list-page' @{ cursor = $null }
        Assert ($a.ok -and $b.ok) 'scan failure leaked snapshot capacity'
        [void](Collect $a); [void](Collect $b)
    }
    $reply = Request 'shutdown'; Assert ($reply.ok -and $reply.result.state -ceq 'partial') 'shutdown'
    Rejected @{ cursor = $null; record = @{ version = 1 } } 'invalid'
    $passed = $true
} catch { $failure = Failure-Context $_ }
finally {
    try {
        if ($started) {
            $phase = 'cleanup-exit'
            $process.StandardInput.Close()
            Assert ($process.WaitForExit(3000)) 'helper did not exit'
            $phase = 'cleanup-stderr'
            Wait-Task $stderr
            Assert ($process.ExitCode -eq 0 -and $stderr.Result.Length -eq 0) 'helper exit/stderr failure'
            if ($passed) { [Console]::Out.WriteLine(('helperExit={0}; stderr={1}' -f $process.ExitCode, $stderr.Result)) }
        }
    } catch {
        $passed = $false
        if ($null -eq $failure) { $failure = Failure-Context $_ } else { $failure += '; cleanup: ' + (Failure-Context $_) }
        if ($started) { try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(3000) } } catch {} }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        # Release every owned synthetic listener before touching any owned file.
        $phase = 'cleanup-pipes'
        foreach ($entry in $pipes.Values) {
            try { $entry.Pipe.Dispose() } catch { $passed = $false; $failure += '; pipe cleanup: ' + (Failure-Context $_) }
            # No AsyncWaitHandle was requested: do not allocate one during teardown.
            # Disposing the overlapped server cancels its pending native accept.
        }
        foreach ($path in $files) {
            try { Remove-File $path } catch { $passed = $false; $failure += '; file cleanup: ' + (Failure-Context $_) }
        }
        $phase = 'cleanup-directories'
        for ($index = $directories.Count - 1; $index -ge 0; $index--) {
            try { [PaginationFixtureIO]::DeleteDirectory((Owned-Path $directories[$index])) }
            catch { $passed = $false; $failure += '; directory cleanup: ' + (Failure-Context $_) }
        }
    }
}
if (-not $passed) { [Console]::Error.WriteLine($failure); exit 1 }
if ($Mode -eq 'legacy-bounds') {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [Console]::Out.WriteLine([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($legacyTrace.ToString())))) } finally { $hash.Dispose() }
}
[Console]::Out.WriteLine('pagination protocol checks passed; disposable profile removed')
