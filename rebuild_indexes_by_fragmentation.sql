/*
================================================================================
Script:       rebuild_indexes_by_fragmentation.sql
Purpose:      Rebuild or reorganize indexes based on fragmentation level,
              following Microsoft's recommended thresholds.
              - Fragmentation 5%–30%  -> REORGANIZE (online, low-impact)
              - Fragmentation > 30%   -> REBUILD (offline unless Enterprise/Azure
                                          SQL supports ONLINE = ON)

Author:        Sriram Krishnamurthy
Script Tested: 12/09/2026 
DB:            Azure SQL Database

Parameters (edit below):
  @MinPageCount        - Ignore small indexes (default 1000 pages, per MS guidance)
  @ReorganizeThreshold - Fragmentation % floor for REORGANIZE
  @RebuildThreshold    - Fragmentation % floor for REBUILD
  @ExecuteCommands     - 0 = print only (dry run), 1 = execute

Notes:
  - On Azure SQL Database, ONLINE = ON is supported for most editions; 
  - Adjust @OnlineRebuild if targeting Standard/Basic tiers with restrictions.

================================================================================
*/

SET NOCOUNT ON;

DECLARE @MinPageCount        INT = 1000;
DECLARE @ReorganizeThreshold FLOAT = 5.0;
DECLARE @RebuildThreshold    FLOAT = 30.0;
DECLARE @ExecuteCommands     BIT = 0;   
DECLARE @OnlineRebuild       BIT = 1;   -- 1 = ONLINE = ON where supported

DECLARE @SchemaName SYSNAME, @TableName SYSNAME, @IndexName SYSNAME;
DECLARE @Fragmentation FLOAT, @PageCount INT;
DECLARE @SQL NVARCHAR(MAX);

-- Staging table for results/audit trail
IF OBJECT_ID('tempdb..#IndexMaintenanceLog') IS NOT NULL
    DROP TABLE #IndexMaintenanceLog;

CREATE TABLE #IndexMaintenanceLog
(
    SchemaName      SYSNAME,
    TableName       SYSNAME,
    IndexName       SYSNAME,
    Fragmentation   FLOAT,
    PageCount       INT,
    ActionTaken     VARCHAR(20),
    CommandText     NVARCHAR(MAX),
    ExecutedAtUtc   DATETIME2 NULL
);

DECLARE index_cursor CURSOR FAST_FORWARD FOR
    SELECT
        s.name  AS SchemaName,
        t.name  AS TableName,
        i.name  AS IndexName,
        ips.avg_fragmentation_in_percent,
        ips.page_count
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
    INNER JOIN sys.indexes  AS i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
    INNER JOIN sys.tables   AS t ON i.object_id = t.object_id
    INNER JOIN sys.schemas  AS s ON t.schema_id = s.schema_id
    WHERE ips.page_count >= @MinPageCount
      AND i.name IS NOT NULL                 -- exclude heaps
      AND ips.avg_fragmentation_in_percent >= @ReorganizeThreshold  -- (5%)
    ORDER BY ips.avg_fragmentation_in_percent DESC;

OPEN index_cursor;
FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @Fragmentation >= @RebuildThreshold -- (30%)
    BEGIN
        SET @SQL = N'ALTER INDEX ' + QUOTENAME(@IndexName) +
                   N' ON ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) +
                   N' REBUILD' +
                   CASE WHEN @OnlineRebuild = 1 THEN N' WITH (ONLINE = ON)' ELSE N'' END + N';';

        INSERT INTO #IndexMaintenanceLog VALUES
            (@SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount, 'REBUILD', @SQL, NULL);
    END
    ELSE
    BEGIN
        SET @SQL = N'ALTER INDEX ' + QUOTENAME(@IndexName) +
                   N' ON ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) +
                   N' REORGANIZE;';
        --PRINT @TableName + ' -- ' + @IndexName + ' -- ' + @Fragmentation + ' -- ' + @PageCount;
        INSERT INTO #IndexMaintenanceLog VALUES
            (@SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount, 'REORGANIZE', @SQL, NULL);
    END

    IF @ExecuteCommands = 1
    BEGIN
        --PRINT 'ExecuteCommands=1';
      
        BEGIN TRY
            EXEC sp_executesql @SQL;
            UPDATE #IndexMaintenanceLog
                SET ExecutedAtUtc = SYSUTCDATETIME()
                WHERE SchemaName = @SchemaName AND TableName = @TableName AND IndexName = @IndexName;
        END TRY
        BEGIN CATCH
            PRINT 'ERROR on ' + @SchemaName + '.' + @TableName + '.' + @IndexName + ': ' + ERROR_MESSAGE();
        END CATCH
    END
    ELSE
    BEGIN
        --PRINT @ExecuteCommnds;
        PRINT @SQL;  -- dry run output
    END

    FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount;
END

CLOSE index_cursor;
DEALLOCATE index_cursor;

-- Summary report
SELECT
    SchemaName, TableName, IndexName,
    Fragmentation = CAST(Fragmentation AS DECIMAL(5,2)),
    PageCount, ActionTaken, ExecutedAtUtc
FROM #IndexMaintenanceLog
ORDER BY Fragmentation DESC;
