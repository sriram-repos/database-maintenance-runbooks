/*
================================================================================
Script:       find_blocking_chains.sql
Purpose:      Identify current blocking chains: which sessions are blocked,
              by whom (the root blocker), how long, and what SQL text is
              running on each side. Can be used for real-time DBA triage.

Author:        Sriram Krishnamurthy
Script Tested: 07/09/2026 
DB:            Azure SQL Database


================================================================================
*/

SET NOCOUNT ON;

;WITH BlockingInfo AS
(
    SELECT
        r.session_id                                   AS BlockedSessionID,
        r.blocking_session_id                          AS BlockingSessionID,
        r.wait_type,
        r.wait_time / 1000.0                           AS WaitTimeSeconds,
        r.status,
        r.command,
        DB_NAME(r.database_id)                         AS DatabaseName,
        s.login_name                                   AS BlockedLoginName,
        s.host_name                                    AS BlockedHostName,
        s.program_name                                 AS BlockedProgramName,
        t.text                                          AS BlockedSQLText
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE r.blocking_session_id <> 0
)
SELECT
    bi.BlockedSessionID,
    bi.BlockingSessionID,
    RootBlocker = CASE
                    WHEN NOT EXISTS (
                        SELECT 1 FROM sys.dm_exec_requests r2
                        WHERE r2.session_id = bi.BlockingSessionID
                          AND r2.blocking_session_id <> 0
                    ) THEN 'YES - investigate this session'
                    ELSE 'No - part of chain, see root above'
                  END,  --Root cause or the first process in a list of sessions blocked
    bi.DatabaseName,
    bi.wait_type,
    WaitTimeSeconds     = CAST(bi.WaitTimeSeconds AS DECIMAL(10,2)),   --this with wait type can identify exclusive lock (LCK_M_X)
    bi.status,
    bi.command,
    bi.BlockedLoginName,
    bi.BlockedHostName,
    bi.BlockedProgramName,
    BlockedSQLText      = LEFT(bi.BlockedSQLText, 500),
    BlockingLoginName   = bs.login_name,
    BlockingSQLText     = LEFT(bt.text, 500),
    BlockingStatus      = br.status
FROM BlockingInfo bi
LEFT JOIN sys.dm_exec_sessions bs ON bi.BlockingSessionID = bs.session_id
LEFT JOIN sys.dm_exec_requests br ON bi.BlockingSessionID = br.session_id
OUTER APPLY sys.dm_exec_sql_text(br.sql_handle) bt
ORDER BY bi.WaitTimeSeconds DESC;   --find the longest-suffering sessions.


