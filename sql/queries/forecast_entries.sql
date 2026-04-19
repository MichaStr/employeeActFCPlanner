-- ============================================================
-- queries/forecast_entries.sql
-- SCD Type 2 operations, monthly rollup, and version diff.
--
-- SCD PATTERN REMINDER
-- ────────────────────
-- Each attribute change is a two-step operation:
--   1. Close the current open row:  set valid_to = change_month.
--   2. Insert the new state:        valid_from = change_month, valid_to = NULL.
--
-- "Active row for month M" predicate (used throughout):
--   valid_from <= M  AND  (valid_to IS NULL OR valid_to > M)  AND  is_deleted = false
--
-- Employee and container entries use separate query pairs because the
-- planner can then choose the appropriate partial index (empl vs cont).
-- ============================================================


-- ── Active-row lookups ────────────────────────────────────────────────────────

-- name: GetActiveEmployeeForecastEntry :one
-- Returns the single active row for a real employee in a given version and month.
--
-- PLAN: idx_fe_version_empl_from (version_id, employee_id, valid_from)
-- INCLUDE (valid_to, fte, costcenter_id, …) WHERE is_deleted = false.
-- The index leaf page contains all projected columns → index-only scan.
SELECT
    id,
    first_name, last_name,
    costcenter_id, classification_id, employee_group_id,
    job_description, fte,
    valid_from, valid_to
FROM  forecast_entries
WHERE version_id  = sqlc.arg(version_id)
  AND employee_id = sqlc.arg(employee_id)
  AND is_deleted  = false
  AND valid_from <= sqlc.arg(month_start)::DATE
  AND (valid_to IS NULL OR valid_to > sqlc.arg(month_start)::DATE)
LIMIT 1;


-- name: GetActiveContainerForecastEntry :one
-- Same as above for planning containers.
--
-- PLAN: idx_fe_version_cont_from.
SELECT
    id,
    first_name, last_name,
    costcenter_id, classification_id, employee_group_id,
    job_description, fte,
    valid_from, valid_to
FROM  forecast_entries
WHERE version_id   = sqlc.arg(version_id)
  AND container_id = sqlc.arg(container_id)
  AND is_deleted   = false
  AND valid_from  <= sqlc.arg(month_start)::DATE
  AND (valid_to IS NULL OR valid_to > sqlc.arg(month_start)::DATE)
LIMIT 1;


-- name: ListActiveEntriesForVersion :many
-- All active entries (employees + containers) in a version for a given month.
-- Used to seed the next working version at month rollover.
--
-- PLAN: idx_fe_version_valid_from (version_id, valid_from) for the range scan;
-- heap access for the remaining columns.  For the seed operation this full
-- scan is expected and unavoidable — it runs once per month.
SELECT
    id,
    employee_id, container_id,
    first_name, last_name,
    costcenter_id, classification_id, employee_group_id,
    job_description, fte,
    valid_from, valid_to
FROM  forecast_entries
WHERE version_id  = sqlc.arg(version_id)
  AND is_deleted  = false
  AND valid_from <= sqlc.arg(month_start)::DATE
  AND (valid_to IS NULL OR valid_to > sqlc.arg(month_start)::DATE)
ORDER BY employee_id NULLS LAST, container_id NULLS LAST;


-- ── SCD Type 2 write operations ───────────────────────────────────────────────

-- name: InsertForecastEntry :one
-- Step 2 of a change: insert the new attribute state.
-- valid_to is NULL for the new open-ended row.
-- Always pair with CloseEmployee/ContainerForecastEntry (step 1) unless
-- this is the very first entry for the subject in this version.
INSERT INTO forecast_entries (
    id,
    version_id,
    employee_id,
    container_id,
    first_name, last_name,
    costcenter_id, classification_id, employee_group_id,
    job_description, fte,
    valid_from,
    is_deleted,
    created_by
) VALUES (
    gen_random_uuid(),
    sqlc.arg(version_id),
    sqlc.narg(employee_id),
    sqlc.narg(container_id),
    sqlc.arg(first_name),
    sqlc.arg(last_name),
    sqlc.arg(costcenter_id),
    sqlc.narg(classification_id),
    sqlc.narg(employee_group_id),
    sqlc.narg(job_description),
    sqlc.arg(fte),
    sqlc.arg(valid_from),
    false,
    sqlc.arg(created_by)
)
RETURNING *;


-- name: CloseEmployeeForecastEntry :execrows
-- Step 1 of a change for a real employee: close the currently open row.
-- valid_to is the first day of the month when the new state takes effect.
--
-- Returns the number of rows updated (should always be 0 or 1).
-- If 0 rows updated, no open row exists — the caller should insert without closing.
--
-- PLAN: idx_fe_version_empl_open (version_id, employee_id)
-- WHERE valid_to IS NULL AND is_deleted = false → single-row key lookup.
UPDATE forecast_entries
SET    valid_to = sqlc.arg(valid_to)::DATE
WHERE  version_id  = sqlc.arg(version_id)
  AND  employee_id = sqlc.arg(employee_id)
  AND  valid_to   IS NULL
  AND  is_deleted  = false;


-- name: CloseContainerForecastEntry :execrows
-- Step 1 for a planning container.
--
-- PLAN: idx_fe_version_cont_open.
UPDATE forecast_entries
SET    valid_to = sqlc.arg(valid_to)::DATE
WHERE  version_id   = sqlc.arg(version_id)
  AND  container_id = sqlc.arg(container_id)
  AND  valid_to    IS NULL
  AND  is_deleted   = false;


-- name: SoftDeleteEmployeeForecastEntry :exec
-- Removes a planned entry without a hard DELETE.
-- The audit trigger fires and logs action = DELETE with the full snapshot.
-- The chk_fe_soft_delete constraint ensures deleted_by + deleted_at are set together.
UPDATE forecast_entries
SET
    is_deleted = true,
    deleted_at = now(),
    deleted_by = sqlc.arg(deleted_by)
WHERE version_id  = sqlc.arg(version_id)
  AND employee_id = sqlc.arg(employee_id)
  AND valid_to   IS NULL
  AND is_deleted  = false;


-- name: SoftDeleteContainerForecastEntry :exec
UPDATE forecast_entries
SET
    is_deleted = true,
    deleted_at = now(),
    deleted_by = sqlc.arg(deleted_by)
WHERE version_id   = sqlc.arg(version_id)
  AND container_id = sqlc.arg(container_id)
  AND valid_to    IS NULL
  AND is_deleted   = false;


-- ── Monthly rollup (WebUI table — the most critical query) ────────────────────

-- name: MonthlyForecastRollupByCC :many
-- Returns total FTE and headcount per costcenter per month for a version.
-- This drives the main WebUI table: rows = costcenters, columns = months.
--
-- PARAMETERS
--   version_id     — which forecast version to read
--   fc_start_month — first month of the grid  (first day of month, e.g. 2025-01-01)
--   fc_end_month   — last  month of the grid  (first day of month, e.g. 2026-06-01)
--
-- QUERY STRATEGY
-- generate_series produces one row per month.  The CROSS JOIN LATERAL
-- tells the planner to execute the subquery independently for each month
-- value, which allows index-only scans on idx_fe_version_cc_from for each
-- (version_id, *, valid_from) prefix.
--
-- Without LATERAL the planner might choose a hash join across all months
-- simultaneously, which forces a full scan of forecast_entries for the
-- version — far more expensive when only the last few months have changes.
--
-- PERFORMANCE NOTE (PG18)
-- ───────────────────────
-- idx_fe_version_cc_from (from migration 004) now includes valid_to and fte
-- via INCLUDE, making this a fully index-only scan — no heap access at all.
--
-- PG18 async I/O reduces heap-fetch latency when the index is cold (first
-- query after restart).  For warm-cache production queries the INCLUDE
-- strategy is what matters most.
--
-- headcount counts all rows (including containers with FTE > 1 or < 0).
-- If you want headcount to count only positive-FTE employees, add a WHERE
-- clause inside the subquery: AND fte > 0 AND employee_id IS NOT NULL.
SELECT
    gs.month_start::DATE                AS month_start,
    fe.costcenter_id,
    SUM(fe.fte)                         AS total_fte,
    COUNT(*)::BIGINT                    AS headcount
FROM generate_series(
    sqlc.arg(fc_start_month)::TIMESTAMPTZ,
    sqlc.arg(fc_end_month)::TIMESTAMPTZ,
    '1 month'::INTERVAL
) AS gs(month_start)
CROSS JOIN LATERAL (
    SELECT costcenter_id, fte
    FROM   forecast_entries
    WHERE  version_id  = sqlc.arg(version_id)
      AND  is_deleted  = false
      AND  valid_from <= gs.month_start::DATE
      AND  (valid_to IS NULL OR valid_to > gs.month_start::DATE)
) AS fe
GROUP BY gs.month_start, fe.costcenter_id
ORDER BY gs.month_start, fe.costcenter_id;


-- ── Version diff ──────────────────────────────────────────────────────────────

-- name: DiffVersionsByCC :many
-- Compares total FTE per costcenter between two forecast versions for a
-- single target month.  Returns only costcenters where the values differ.
--
-- Use cases:
--   • Compare two archived snapshots (e.g. last month's FC vs this month's FC)
--   • Compare the working version against the previous snapshot
--
-- BOTH CTEs are marked MATERIALIZED so the planner executes each exactly
-- once against its respective version_id, using idx_fe_version_cc_from.
-- Without MATERIALIZED, PG12+ may inline the CTEs; while that is safe here,
-- it prevents the parallel execution hint that PG18 uses when both CTEs
-- reference different version_ids (no shared data dependency).
--
-- PERFORMANCE NOTE (PG18)
-- PG18's improved parallel query infrastructure can run both CTE scans
-- concurrently when max_parallel_workers_per_gather > 0 and the table is
-- large enough to trigger parallelism.  MATERIALIZED makes the independence
-- of the two scans explicit to the planner.
WITH version_a AS MATERIALIZED (
    SELECT fe.costcenter_id, SUM(fe.fte) AS total_fte
    FROM   forecast_entries fe
    WHERE  fe.version_id = sqlc.arg(version_a_id)
      AND  fe.is_deleted  = false
      AND  fe.valid_from <= sqlc.arg(month_start)::DATE
      AND  (fe.valid_to IS NULL OR fe.valid_to > sqlc.arg(month_start)::DATE)
    GROUP  BY fe.costcenter_id
),
version_b AS MATERIALIZED (
    SELECT fe.costcenter_id, SUM(fe.fte) AS total_fte
    FROM   forecast_entries fe
    WHERE  fe.version_id = sqlc.arg(version_b_id)
      AND  fe.is_deleted  = false
      AND  fe.valid_from <= sqlc.arg(month_start)::DATE
      AND  (fe.valid_to IS NULL OR fe.valid_to > sqlc.arg(month_start)::DATE)
    GROUP  BY fe.costcenter_id
)
SELECT
    COALESCE(a.costcenter_id, b.costcenter_id)      AS costcenter_id,
    a.total_fte                                      AS fte_version_a,
    b.total_fte                                      AS fte_version_b,
    COALESCE(b.total_fte, 0) - COALESCE(a.total_fte, 0) AS fte_delta
FROM  version_a a
FULL  OUTER JOIN version_b b ON a.costcenter_id = b.costcenter_id
WHERE a.total_fte IS DISTINCT FROM b.total_fte
ORDER BY COALESCE(a.costcenter_id, b.costcenter_id);


-- name: DiffVersionsByEmployee :many
-- Row-level diff between two versions for a given month.
-- Returns every subject (employee or container) where any tracked attribute
-- changed — costcenter_id, classification_id, employee_group_id, or fte.
--
-- Rows present only in version A (employee left the FC) have *_b columns NULL.
-- Rows present only in version B (employee added to FC) have *_a columns NULL.
--
-- COALESCE join key: both employee_id and container_id are UUID, but a given
-- subject only appears in one column per row (chk_fe_subject_exclusive).
-- We cast both to TEXT for FULL OUTER JOIN — the cast is cheap, and UUID
-- comparison is always by value so no false matches occur.
--
-- PLAN: each CTE uses idx_fe_version_empl_from / idx_fe_version_cont_from
-- (from migration 004) for index-only scans on the key columns.
WITH version_a AS MATERIALIZED (
    SELECT
        COALESCE(fe.employee_id::TEXT, fe.container_id::TEXT) AS subject_key,
        fe.employee_id,
        fe.container_id,
        fe.costcenter_id,
        fe.classification_id,
        fe.employee_group_id,
        fe.fte
    FROM  forecast_entries fe
    WHERE fe.version_id = sqlc.arg(version_a_id)
      AND fe.is_deleted  = false
      AND fe.valid_from <= sqlc.arg(month_start)::DATE
      AND (fe.valid_to IS NULL OR fe.valid_to > sqlc.arg(month_start)::DATE)
),
version_b AS MATERIALIZED (
    SELECT
        COALESCE(fe.employee_id::TEXT, fe.container_id::TEXT) AS subject_key,
        fe.employee_id,
        fe.container_id,
        fe.costcenter_id,
        fe.classification_id,
        fe.employee_group_id,
        fe.fte
    FROM  forecast_entries fe
    WHERE fe.version_id = sqlc.arg(version_b_id)
      AND fe.is_deleted  = false
      AND fe.valid_from <= sqlc.arg(month_start)::DATE
      AND (fe.valid_to IS NULL OR fe.valid_to > sqlc.arg(month_start)::DATE)
)
SELECT
    COALESCE(a.subject_key,      b.subject_key)      AS subject_key,
    COALESCE(a.employee_id,      b.employee_id)      AS employee_id,
    COALESCE(a.container_id,     b.container_id)     AS container_id,
    a.costcenter_id                                  AS costcenter_id_a,
    b.costcenter_id                                  AS costcenter_id_b,
    a.classification_id                              AS classification_id_a,
    b.classification_id                              AS classification_id_b,
    a.employee_group_id                              AS employee_group_id_a,
    b.employee_group_id                              AS employee_group_id_b,
    a.fte                                            AS fte_a,
    b.fte                                            AS fte_b,
    COALESCE(b.fte, 0) - COALESCE(a.fte, 0)         AS fte_delta
FROM  version_a a
FULL  OUTER JOIN version_b b ON a.subject_key = b.subject_key
WHERE a.costcenter_id     IS DISTINCT FROM b.costcenter_id
   OR a.classification_id IS DISTINCT FROM b.classification_id
   OR a.employee_group_id IS DISTINCT FROM b.employee_group_id
   OR a.fte               IS DISTINCT FROM b.fte
ORDER BY COALESCE(a.subject_key, b.subject_key);


-- ── Audit history ─────────────────────────────────────────────────────────────

-- name: GetAuditHistoryForEntry :many
-- Full change history for a single forecast_entries row, newest first.
-- Used by the "change history" drawer in the UI.
SELECT
    id,
    action,
    changed_fields,
    changed_by,
    changed_at,
    client_ip
FROM  forecast_entry_audit
WHERE forecast_entry_id = sqlc.arg(forecast_entry_id)
ORDER BY changed_at DESC;


-- name: GetAuditHistoryForVersion :many
-- All changes made to a forecast version, newest first.
-- Used by the "version activity log" panel.
-- Limit to a reasonable page size in the application layer.
SELECT
    fea.id,
    fea.forecast_entry_id,
    fea.action,
    fea.changed_fields,
    fea.changed_by,
    fea.changed_at,
    fe.employee_id,
    fe.container_id,
    fe.costcenter_id
FROM  forecast_entry_audit fea
JOIN  forecast_entries     fe  ON fe.id = fea.forecast_entry_id
WHERE fea.version_id = sqlc.arg(version_id)
ORDER BY fea.changed_at DESC
LIMIT  sqlc.arg(limit_rows)::BIGINT;
