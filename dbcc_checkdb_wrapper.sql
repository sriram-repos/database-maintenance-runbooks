/*
================================================================================
Script:       dbcc_checkdb_wrapper.sql
Purpose:      Run DBCC CHECKDB against one or all user databases, capture
              results into a permanent log table, log file and email the data to DBA team 
              and flag corruption.
              Designed to be run as a scheduled SQL Agent job step.
Author:       Sriram Krishnamurthy
Last tested:  16/09/2026

Parameters:
  @TargetDatabase - DB name or NULL to check all user databases
  @PhysicalOnly   - 1 = DBCC CHECKDB WITH PHYSICAL_ONLY (faster, catches
                    most storage corruption, suits run daily)
                  - 0 = full logical & physical check (slower, weekly)
================================================================================
*/

SET NOCOUNT ON;

DECLARE @TargetDatabase SYSNAME = NULL;   -- NULL = all user databases
DECLARE @PhysicalOnly   BIT = 1;

IF OBJECT_ID('dbo.CheckDBHistory') IS NULL
BEGIN
    CREATE TABLE dbo.CheckDBHistory
    (
        LogID           INT IDENTITY PRIMARY KEY,
        DatabaseName    SYSNAME,
        StartTimeUtc    DATETIME2,
        EndTimeUtc      DATETIME2,
        PhysicalOnly    BIT,
        HasErrors       BIT,
        ResultMessage   NVARCHAR(MAX)
    );
END

DECLARE @DBName SYSNAME;
DECLARE @SQL NVARCHAR(MAX);
DECLARE @StartTime DATETIME2, @EndTime DATETIME2;
DECLARE @ErrorText NVARCHAR(MAX);
DECLARE @Cmd NVARCHAR(4000);

DECLARE db_cursor CURSOR FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4
      AND (@TargetDatabase IS NULL OR name = @TargetDatabase);

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @StartTime = SYSUTCDATETIME();
    SET @ErrorText = NULL;
    
    --PRINT @StartTime

    SET @SQL = N'DBCC CHECKDB (' + QUOTENAME(@DBName) + N')' +
               CASE WHEN @PhysicalOnly = 1 THEN N' WITH PHYSICAL_ONLY, NO_INFOMSGS'
                    ELSE N' WITH NO_INFOMSGS' END + N';';

    BEGIN TRY
        EXEC sp_executesql @SQL;
        SET @EndTime = SYSUTCDATETIME();
        
        --PRINT 'TRY' + ' - ' + @EndTime + ' - ' + @DBName

        INSERT INTO dbo.CheckDBHistory (DatabaseName, StartTimeUtc, EndTimeUtc, PhysicalOnly, HasErrors, ResultMessage)
        VALUES (@DBName, @StartTime, @EndTime, @PhysicalOnly, 0, 'CHECKDB completed with no errors.');
    END TRY
    BEGIN CATCH
        SET @EndTime = SYSUTCDATETIME();
        SET @ErrorText = ERROR_MESSAGE();
        
        --PRINT 'CATCH' + ' - ' + @EndTime + ' - ' + @DBName

        INSERT INTO dbo.CheckDBHistory (DatabaseName, StartTimeUtc, EndTimeUtc, PhysicalOnly, HasErrors, ResultMessage)
        VALUES (@DBName, @StartTime, @EndTime, @PhysicalOnly, 1, @ErrorText);

        -- Use sp_notify_operator or sp_send_dbmail to alert DB team
        -- PRINT 'CORRUPTION OR ERROR DETECTED in ' + @DBName + ': ' + @ErrorText;
        -- Sending error message to Log file which will then be sent out to DBA team through Windows Process.
        SET @Cmd = 'echo ' + @DBName + ': ' + @ErrorText + ' >> C:\Logs\sql_errors.txt';
        EXEC xp_cmdshell @Cmd, no_output;
        
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DBName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Summary of most recent run
SELECT TOP 50 *
FROM dbo.CheckDBHistory
ORDER BY LogID DESC;
