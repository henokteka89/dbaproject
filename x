/* ============================================================
   Step 2: Get snapshot of active requests
   ============================================================ */

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

DECLARE @SnapshotDate datetime = GETDATE();

/* CHANGE 1: only the columns the main query really uses; seq = insertion order */
DECLARE @blocked TABLE
(
    dbid                SMALLINT NOT NULL,
    session_id          SMALLINT NOT NULL,
    blocking_session_id SMALLINT NOT NULL,
    seq                 INT IDENTITY(1,1) NOT NULL
);

/* Populate @blocked with all sessions that are actively blocking others.
   CHANGE 2: DMVs instead of sys.sysprocesses (no self-join of the slow view).
     r2 = blocked request, s1 = the blocker session (its current database) */
INSERT INTO @blocked (dbid, session_id, blocking_session_id)
SELECT ISNULL(s1.database_id, 0), r2.session_id, r2.blocking_session_id
FROM sys.dm_exec_requests AS r2
JOIN sys.dm_exec_sessions AS s1
    ON s1.session_id = r2.blocking_session_id
WHERE r2.blocking_session_id > 0;

/* CHANGE 3: build the lookup once (one row per session id, first inserted row wins) */
DECLARE @blocked_lookup TABLE
(
    lookup_id           SMALLINT NOT NULL PRIMARY KEY,
    dbid                SMALLINT NOT NULL,
    session_id          SMALLINT NOT NULL,
    blocking_session_id SMALLINT NOT NULL
);

;WITH k AS
(
    SELECT lookup_id = b.session_id,          b.seq, b.dbid, b.session_id, b.blocking_session_id
    FROM @blocked AS b
    UNION ALL
    SELECT lookup_id = b.blocking_session_id, b.seq, b.dbid, b.session_id, b.blocking_session_id
    FROM @blocked AS b
),
r AS
(
    SELECT k.lookup_id, k.dbid, k.session_id, k.blocking_session_id,
           rn = ROW_NUMBER() OVER (PARTITION BY k.lookup_id ORDER BY k.seq)
    FROM k
)
INSERT INTO @blocked_lookup (lookup_id, dbid, session_id, blocking_session_id)
SELECT lookup_id, dbid, session_id, blocking_session_id
FROM r
WHERE rn = 1;

SELECT
    snapshot_date = @SnapshotDate,
    /* Strip '**' masking artifacts from SQL text before storing */
    [text]        = LEFT(REPLACE(sql_text.[text], '**', ''), 30000),
    [db_name]     = DB_NAME(r.database_id),
    [object_name] = OBJECT_NAME(sql_text.objectid, sql_text.dbid),
    s.[session_id],
    request_status = r.[status],
    blocking_session_id =
        CASE
            WHEN r.blocking_session_id <> 0
                 AND blocked.session_id IS NULL
                THEN r.blocking_session_id
            WHEN r.blocking_session_id <> 0
                 AND s.session_id <> blocked.blocking_session_id
                THEN blocked.blocking_session_id
            WHEN r.blocking_session_id = 0
                 AND s.session_id = blocked.session_id
                THEN blocked.blocking_session_id
            WHEN r.blocking_session_id <> 0
                 AND s.session_id = blocked.blocking_session_id
                THEN r.blocking_session_id
            ELSE NULL
        END,
    running_seconds =
        CASE
            WHEN s.last_request_start_time >= DATEADD(YEAR, -1, GETDATE())
                THEN DATEDIFF(SECOND, s.last_request_start_time, DATEADD(SECOND, 1, GETDATE()))
            ELSE NULL
        END,
    cpu_time =
        CASE
            WHEN r.cpu_time BETWEEN 0 AND 86399999
                THEN CONVERT(time, DATEADD(MILLISECOND, r.cpu_time, 0))
            ELSE NULL
        END,
    s.[host_name],
    s.[program_name],
    s.login_name,
    qmg.query_cost,
    r.wait_type,
    wait_time =
        CASE
            WHEN r.wait_time BETWEEN 0 AND 86399999
                THEN CONVERT(time, DATEADD(MILLISECOND, r.wait_time, 0))
            ELSE NULL
        END,
    wait_resource = r.wait_resource,
    r.last_wait_type,
    s.last_request_end_time,
    r.start_time,
    CAST(qp.query_plan AS NVARCHAR(MAX))
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r
    ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_query_memory_grants AS qmg
    ON  qmg.session_id = r.session_id
    AND qmg.request_id = r.request_id
LEFT JOIN sys.dm_exec_connections AS ec
    ON ec.session_id = s.session_id
LEFT JOIN sys.dm_tran_session_transactions AS t
    ON t.session_id = s.session_id
/* replaces the old OUTER APPLY ... TOP (1) ... AS blocked */
LEFT JOIN @blocked_lookup AS blocked
    ON blocked.lookup_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, ec.most_recent_sql_handle)) AS sql_text
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE s.session_id <> @@SPID
AND   sql_text.[text] IS NOT NULL
AND   s.host_name IS NOT NULL
AND
(
    ISNULL(DB_NAME(r.database_id), DB_NAME(blocked.dbid)) IS NOT NULL
    OR s.session_id IN
    (
        SELECT b2.blocking_session_id
        FROM @blocked AS b2
    )
)
AND ISNULL(DB_NAME(r.database_id), '') NOT IN ('distribution', 'msdb', 'tempdb')
--option (fast 10)
go