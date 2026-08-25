<#
.SYNOPSIS
    Clean-RAM.ps1 - Frees physical RAM on Windows.

.DESCRIPTION
    Performs a full memory cleanup using native NT kernel calls:
      1. Empties working sets of all processes (like RAMMap > Empty Working Sets)
      2. Purges low-priority standby list
      3. Purges standby list (cached memory)
      4. Optional: flushes modified page list  (-FlushModifiedList)

    Self-elevates to Administrator via UAC if not already elevated.
    A summary of every run is appended to %TEMP%\Clean-RAM.log.

.EXAMPLE
    .\Clean-RAM.ps1
    .\Clean-RAM.ps1 -FlushModifiedList
    .\Clean-RAM.ps1 -NoTrim          # only purge caches, don't touch running apps
#>

[CmdletBinding()]
param(
    [switch]$FlushModifiedList,
    [switch]$NoTrim
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $env:TEMP 'Clean-RAM.log'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- elevation
if (-not (Test-IsAdmin)) {
    Write-Host 'Administrator rights required - requesting elevation (UAC)...' -ForegroundColor Yellow
    $switches = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) { $switches += "-$k" }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $switches -Verb RunAs -Wait
    }
    catch {
        Write-Host 'Elevation was cancelled. Nothing was cleaned.' -ForegroundColor Red
        exit 1
    }
    if (Test-Path $LogFile) { Get-Content $LogFile | Select-Object -Last 10 }
    exit
}

# ---------------------------------------------------------------- native API
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RamCleaner
{
    private const int SystemMemoryListInformation = 80;

    // SYSTEM_MEMORY_LIST_COMMAND (winternl.h)
    private const int MemoryEmptyWorkingSets           = 3;
    private const int MemoryFlushModifiedList          = 4;
    private const int MemoryPurgeStandbyList           = 5;
    private const int MemoryPurgeLowPriorityStandbyList = 6;

    private const int SeProfileSingleProcessPrivilege = 13;

    [DllImport("ntdll.dll")]
    private static extern int NtSetSystemInformation(int infoClass, ref int info, int length);

    [DllImport("ntdll.dll")]
    private static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool previous);

    private static void SendCommand(int command)
    {
        bool prev;
        int status = RtlAdjustPrivilege(SeProfileSingleProcessPrivilege, true, false, out prev);
        if (status != 0)
            throw new InvalidOperationException(string.Format(
                "Could not acquire SeProfileSingleProcessPrivilege (NTSTATUS 0x{0:X8}).", status));

        status = NtSetSystemInformation(SystemMemoryListInformation, ref command, sizeof(int));
        if (status != 0)
            throw new InvalidOperationException(string.Format(
                "Kernel memory command {0} failed (NTSTATUS 0x{1:X8}).", command, status));
    }

    public static void TrimWorkingSets()        { SendCommand(MemoryEmptyWorkingSets); }
    public static void PurgeStandby()           { SendCommand(MemoryPurgeStandbyList); }
    public static void PurgeLowPriorityStandby(){ SendCommand(MemoryPurgeLowPriorityStandbyList); }
    public static void FlushModifiedList()      { SendCommand(MemoryFlushModifiedList); }
}
'@

# ---------------------------------------------------------------- helpers
function Get-MemStats {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        TotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        FreeGB  = [math]::Round($os.FreePhysicalMemory  / 1MB, 2)
    }
}

function Show-Stats([string]$Label, $Stats) {
    $usedGB = [math]::Round($Stats.TotalGB - $Stats.FreeGB, 2)
    $pct = [math]::Round($usedGB / $Stats.TotalGB * 100)
    $line = ('{0,-8} Free: {1,6} GB / {2} GB   (Used: {3} GB / {4}%)' -f `
        $Label, $Stats.FreeGB, $Stats.TotalGB, $usedGB, $pct)
    Write-Host $line
}

function Log([string]$Text, [string]$Color = 'White') {
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
}

# ---------------------------------------------------------------- main
Clear-Host
Log ('=' * 60)
Log 'RAM cleanup started'

$before = Get-MemStats
Show-Stats 'BEFORE' $before

try {
    foreach ($step in @(
        @{ Name = 'Emptying working sets of all processes'; Action = { [RamCleaner]::TrimWorkingSets() }; Skip = $NoTrim },
        @{ Name = 'Purging low-priority standby list';      Action = { [RamCleaner]::PurgeLowPriorityStandby() }; Skip = $false },
        @{ Name = 'Purging standby list (file cache)';      Action = { [RamCleaner]::PurgeStandby() }; Skip = $false },
        @{ Name = 'Flushing modified page list';            Action = { [RamCleaner]::FlushModifiedList() }; Skip = -not $FlushModifiedList }
    )) {
        if ($step.Skip) { continue }
        Write-Host ('{0}...' -f $step.Name) -ForegroundColor Cyan
        try {
            & $step.Action
        }
        catch {
            Log ("SKIPPED: {0} ({1})" -f $step.Name, $_.Exception.Message) 'Yellow'
            Write-Host '  not supported on this system - skipped.' -ForegroundColor Yellow
        }
    }
}
catch {
    Log ("FAILED: {0}" -f $_.Exception.Message) 'Red'
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Start-Sleep -Milliseconds 700
$after = Get-MemStats
Show-Stats 'AFTER' $after

$freed = [math]::Round($after.FreeGB - $before.FreeGB, 2)
Log ("Cleanup finished - freed ~{0} GB." -f $freed) 'Green'
Write-Host ''
Write-Host ("Done. Freed ~{0} GB of RAM." -f $freed) -ForegroundColor Green
