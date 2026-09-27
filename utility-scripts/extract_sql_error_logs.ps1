<#

.WHAT THIS SCRIPT DOES
    	Script Headers & Inputs: Accepts server instances, target directory, and time window
	Directory & Time Setup: Verifies .\logs folder existence and calculates the target date window
	Looping SQL Query: Connects to each SQL server instance, executes xp_readerrorlog into a temp table (#ErrorLog), and filters for keyword matches (error, fail, severity, corrupt)
	Data Tagging: Tag each returned record with its SourceInstance to distinguish records when combining multi-server outputs
	CSV Export: Combines all captured logs and writes them out to a timestamped CSV file (sql_error_log_extract_YYYYMMDD_HHMMSS.csv)

.CREATED BY
    Author:       Sriram Krishnamurthy
    Date:  	  Sept 2026


.Array of instance names to check, e.g. @("SERVER1\SQL2022","SERVER2")
.Folder to write CSV output to. Created if it doesn't exist.
.Only include log entries for the past 24 hours.

.   .\extract_sql_error_logs.ps1 -SqlInstances "SERVER1","SERVER2" -HoursBack 24
#>

param(
    #Mandatory parameter. Can't proceed without a SQL Server instance
    [Parameter(Mandatory = $true)]
    [string[]]$SqlInstances,

    #Store your error logs. Archiving is a separate process.
    [string]$OutputFolder = ".\logs",

    #Lookback period. I've defaulted this to 24 hours. Uusual diagnostics lookback period.
    [int]$HoursBack = 24
)

#Official Powershell module for SQL to use Invoke-Sql cmd
Import-Module SqlServer -ErrorAction Stop

#Check if output folder is present else create.
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

$cutoffTime = (Get-Date).AddHours(-$HoursBack)
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
#this array collects all error log entries
$allResults = @()

#start the error log collection for every instance provided.
#for each instance provided execute the system procedure xp_readerrorlog 
#store the result into temporary table ErrorLog. You have to define temp table based on exact resultset from xp_readerrorlog

foreach ($instance in $SqlInstances) {

    Write-Host "Querying error log on $instance ..." -ForegroundColor White

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
            #Running this for multiple instances this will attach SourceInstance as property to map errorlog to instance.
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
