/* ============================================================
   Step 2: Get snapshot of active requests
   ============================================================ */

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

DECLARE @SnapshotDate datetime = GETDATE();

/* CHANGE 1: added seq (insertion order) as the last column */
DECLARE @blocked TABLE
(
    dbid                SMALLINT   NOT NULL,
    last_batch          DATETIME   NOT NULL,
    open_tran           SMALLINT   NOT NULL,
    sql_handle          BINARY(20) NOT NULL,
    session_id          SMALLINT   NOT NULL,
    blocking_session_id SMALLINT   NOT NULL,
    lastwaittype        NCHAR(32)  NOT NULL,
    waittime            BIGINT     NOT NULL,
    cpu                 INT        NOT NULL,
    physical_io         BIGINT     NOT NULL,
    memusage            INT        NOT NULL,
    seq                 INT IDENTITY(1,1) NOT NULL
);

/* Populate @blocked with all sessions that are actively blocking others */
INSERT INTO @blocked (dbid,last_batch,open_tran,sql_handle,session_id,blocking_session_id,lastwaittype,waittime,cpu,physical_io,memusage)
SELECT sys1.dbid,sys1.last_batch,sys1.open_tran,sys1.sql_handle,sys2.spid,sys2.blocked,sys2.lastwaittype,sys2.waittime,sys2.cpu,sys2.physical_io,sys2.memusage
FROM sys.sysprocesses (NOLOCK) AS sys1
JOIN sys.sysprocesses (NOLOCK) AS sys2 ON sys2.blocked = sys1.spid;

/* CHANGE 2: build the lookup once (one row per session id, first inserted row wins) */
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
/* CHANGE 3: LEFT JOIN to the lookup replaces the old OUTER APPLY ... TOP (1) ... AS blocked */
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
