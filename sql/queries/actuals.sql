-- ============================================================
-- queries/actuals.sql
-- SAP/Excel import tracking and employee_actuals queries.
--
-- All employee_actuals rows are IMMUTABLE after insert.
-- There are no UPDATE or DELETE queries in this file by design.
-- ============================================================


-- ── Import run management ─────────────────────────────────────────────────────

-- name: InsertImportRun :one
INSERT INTO import_runs (id, period_year, period_month, status, source_file, imported_by)
VALUES (
    gen_random_uuid(),
    sqlc.arg(period_year),
    sqlc.arg(period_month),
    'completed',
    sqlc.narg(source_file),
    sqlc.arg(imported_by)
)
RETURNING *;


-- name: UpdateImportRunRowCount :exec
-- Called after the bulk insert of employee_actuals to record the final count.
UPDATE import_runs
SET    row_count = sqlc.arg(row_count)
WHERE  id = sqlc.arg(id);


-- name: GetImportRunByID :one
SELECT id, period_year, period_month, status, row_count, source_file, imported_by, imported_at
FROM   import_runs
WHERE  id = sqlc.arg(id);


-- name: GetImportRunByPeriod :one
-- Exact period lookup.  Used before an import to detect duplicate runs.
SELECT id, period_year, period_month, status, row_count, imported_by, imported_at
FROM   import_runs
WHERE  period_year  = sqlc.arg(period_year)
  AND  period_month = sqlc.arg(period_month);


-- name: GetLatestCompletedImportRun :one
-- Returns the most recent successfully completed import.
-- Driving query for "current actual month" comparisons.
--
-- PLAN: idx_import_runs_status filters to 'completed', then a sort on
-- (period_year DESC, period_month DESC) with LIMIT 1 is cheap because
-- import_runs has at most ~120 rows after 10 years of monthly imports.
SELECT id, period_year, period_month, row_count, imported_at
FROM   import_runs
WHERE  status = 'completed'
ORDER  BY period_year DESC, period_month DESC
LIMIT  1;


-- name: ListImportRuns :many
-- Full history, newest first.
SELECT id, period_year, period_month, status, row_count, imported_at
FROM   import_runs
ORDER  BY period_year DESC, period_month DESC;


-- ── employee_actuals insert (called in bulk via CopyFrom at import time) ──────

-- name: InsertEmployeeActual :one
-- Single-row variant used for testing and small corrections.
-- For production imports, use pgx CopyFrom for bulk inserts instead.
INSERT INTO employee_actuals (
    id,
    import_run_id,
    employee_id,
    first_name,
    last_name,
    costcenter_id,
    classification_id,
    employee_group_id,
    job_description,
    fte
) VALUES (
    gen_random_uuid(),
    sqlc.arg(import_run_id),
    sqlc.arg(employee_id),
    sqlc.arg(first_name),
    sqlc.arg(last_name),
    sqlc.arg(costcenter_id),
    sqlc.narg(classification_id),
    sqlc.narg(employee_group_id),
    sqlc.narg(job_description),
    sqlc.arg(fte)
)
RETURNING *;


-- ── Actuals queries ───────────────────────────────────────────────────────────

-- name: GetActualsForEmployee :many
-- Full history of an employee across all import runs, newest first.
-- Useful for the "employee detail" panel in the WebUI.
SELECT
    ea.id,
    ir.period_year,
    ir.period_month,
    ea.first_name,
    ea.last_name,
    ea.costcenter_id,
    ea.classification_id,
    ea.employee_group_id,
    ea.job_description,
    ea.fte
FROM  employee_actuals ea
JOIN  import_runs      ir ON ir.id = ea.import_run_id
WHERE ea.employee_id = sqlc.arg(employee_id)
ORDER BY ir.period_year DESC, ir.period_month DESC;


-- name: ActualsRollupByCC :many
-- Sums FTE and headcount per costcenter for a single import run.
-- Used for the "Actuals" column set in the WebUI table.
--
-- PLAN: idx_employee_actuals_run_cc (import_run_id, costcenter_id) is a
-- covering index for the GROUP BY — PostgreSQL can aggregate without a
-- heap fetch if the FTE column is included.  If the table grows very large,
-- add INCLUDE (fte) to that index (analogous to migration 004).
SELECT
    ea.costcenter_id,
    SUM(ea.fte)    AS total_fte,
    COUNT(*)       AS headcount
FROM  employee_actuals ea
WHERE ea.import_run_id = sqlc.arg(import_run_id)
GROUP BY ea.costcenter_id
ORDER BY ea.costcenter_id;


-- name: ActualsMoMDelta :many
-- Month-over-month delta per costcenter between two import runs.
-- Covers the comparison: "last actual month vs current actual month".
--
-- Returns one row per costcenter that appears in either run.
-- Rows present only in prev_run_id have curr_fte = NULL (new leaver).
-- Rows present only in curr_run_id have prev_fte = NULL (new joiner).
--
-- PERFORMANCE NOTE (PG18)
-- Each CTE is a simple aggregation on import_run_id + costcenter_id,
-- hitting idx_employee_actuals_run_cc.  PG18 parallel aggregation can
-- execute both CTEs concurrently when the planner chooses parallel mode.
-- Mark both CTEs MATERIALIZED so the planner runs each exactly once
-- rather than trying to merge them into a single scan.
WITH prev AS MATERIALIZED (
    SELECT ea.costcenter_id, SUM(ea.fte) AS total_fte
    FROM   employee_actuals ea
    WHERE  ea.import_run_id = sqlc.arg(prev_run_id)
    GROUP  BY ea.costcenter_id
),
curr AS MATERIALIZED (
    SELECT ea.costcenter_id, SUM(ea.fte) AS total_fte
    FROM   employee_actuals ea
    WHERE  ea.import_run_id = sqlc.arg(curr_run_id)
    GROUP  BY ea.costcenter_id
)
SELECT
    COALESCE(curr.costcenter_id, prev.costcenter_id) AS costcenter_id,
    prev.total_fte                                   AS prev_fte,
    curr.total_fte                                   AS curr_fte,
    COALESCE(curr.total_fte, 0) - COALESCE(prev.total_fte, 0) AS delta_fte
FROM  curr
FULL  OUTER JOIN prev ON curr.costcenter_id = prev.costcenter_id
ORDER BY COALESCE(curr.costcenter_id, prev.costcenter_id);
