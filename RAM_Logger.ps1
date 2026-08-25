$logPath = "$env:USERPROFILE\Desktop\RAM_Usage_Log.csv"

# Remove old log so we start fresh with correct headers
if (Test-Path $logPath) { Remove-Item $logPath }

while ($true) {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalRam = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeRam  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $topProcs = Get-Process |
        Group-Object ProcessName |
        Select-Object Name, @{N='TotalMB';E={[math]::Round(($_.Group | Measure-Object WorkingSet -Sum).Sum/1MB,0)}} |
        Sort-Object TotalMB -Descending |
        Select-Object -First 8 |
        ForEach-Object { "$($_.Name)=$($_.TotalMB)MB" }

    $topProcsString = ($topProcs -join " | ")

    # Build a proper CSV row object so quoting/commas are handled automatically
    $row = [PSCustomObject]@{
        Timestamp        = $timestamp
        Total_RAM_GB     = $totalRam
        Available_RAM_GB = $freeRam
        Top_Processes    = $topProcsString
    }

    $row | Export-Csv -Path $logPath -Append -NoTypeInformation

    # Print to console so you can see it's actually working
    Write-Host "[$timestamp] Total: $totalRam GB | Free: $freeRam GB | Top: $topProcsString"

    Start-Sleep -Seconds 10
}
