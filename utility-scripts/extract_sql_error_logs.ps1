<#

.WHAT THIS SCRIPT DOES
    Uses the SqlServer PowerShell module to query sys.xp_readerrorlog-style
    output via Invoke-Sqlcmd against xp_readerrorlog. Filters for entries
    containing common severity/error indicators and exports a clean CSV
    per run, timestamped.

.CREATED BY
    Author:       Sriram Krishnamurthy
    Date:  	  Sept 2026


.Array of instance names to check, e.g. @("SERVER1\SQL2022","SERVER2")
.Folder to write CSV output to. Created if it doesn't exist.
.Only include log entries for the past 24 hours.

.   .\extract_sql_error_logs.ps1 -SqlInstances "SERVER1","SERVER2" -HoursBack 24
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$SqlInstances,

    [string]$OutputFolder = ".\logs",

    [int]$HoursBack = 24
)

Import-Module SqlServer -ErrorAction Stop

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

$cutoffTime = (Get-Date).AddHours(-$HoursBack)
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$allResults = @()

foreach ($instance in $SqlInstances) {

    Write-Host "Querying error log on $instance ..." -ForegroundColor Cyan

    try {
        $query = @"
CREATE TABLE #ErrorLog (
    LogDate DATETIME,
    ProcessInfo NVARCHAR(50),
    Text NVARCHAR(MAX)
);

INSERT INTO #ErrorLog
EXEC xp_readerrorlog 0, 1;

SELECT LogDate, ProcessInfo, Text
FROM #ErrorLog
WHERE LogDate >= '$($cutoffTime.ToString("yyyy-MM-dd HH:mm:ss"))'
  AND (
        Text LIKE '%error%'
     OR Text LIKE '%fail%'
     OR Text LIKE '%severity%'
     OR Text LIKE '%corrupt%'
  )
ORDER BY LogDate DESC;

DROP TABLE #ErrorLog;
"@

        $results = Invoke-Sqlcmd -ServerInstance $instance -Query $query -ErrorAction Stop

        if ($results) {
            $results | Add-Member -MemberType NoteProperty -Name "SourceInstance" -Value $instance
            $allResults += $results
            Write-Host "  Found $($results.Count) matching entries." -ForegroundColor Yellow
        }
        else {
            Write-Host "  No matching entries in the last $HoursBack hours." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed to query $instance : $($_.Exception.Message)"
    }
}

if ($allResults.Count -gt 0) {
    $outputFile = Join-Path $OutputFolder "sql_error_log_extract_$timestamp.csv"
    $allResults | Select-Object SourceInstance, LogDate, ProcessInfo, Text |
        Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

    Write-Host "`nExported $($allResults.Count) total entries to $outputFile" -ForegroundColor Green
}
else {
    Write-Host "`nNo error/failure entries found across any instance in the given window." -ForegroundColor Green
}
