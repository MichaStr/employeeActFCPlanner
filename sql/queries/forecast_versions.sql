-- ============================================================
-- queries/forecast_versions.sql
-- Version lifecycle management: create, archive, seed, diff chain.
-- ============================================================


-- name: GetWorkingForecastVersion :one
-- There is at most one working version at any time (partial unique index
-- uq_fc_versions_one_working enforces this at the DB level).
-- Returns an error if no working version exists yet.
--
-- PLAN: index scan on idx_fc_versions_status, then LIMIT 1.
SELECT id, label, period_year, period_month, fc_horizon_months, source_version_id, created_at
FROM   forecast_versions
WHERE  status = 'working'
LIMIT  1;


-- name: GetForecastVersionByID :one
SELECT
    id, label, status,
    period_year, period_month, fc_horizon_months,
    source_version_id,
    archived_at, archived_by,
    created_by, created_at
FROM  forecast_versions
WHERE id = sqlc.arg(id);


-- name: ListForecastVersions :many
-- All versions newest-first.  Used for the version picker in the WebUI.
SELECT
    id, label, status,
    period_year, period_month,
    source_version_id,
    archived_at, created_at
FROM  forecast_versions
ORDER BY period_year DESC, period_month DESC, created_at DESC;


-- name: InsertForecastVersion :one
-- Creates a new working version.
-- source_version_id is NULL only for the very first version ever created;
-- in all subsequent months it points to the just-archived snapshot.
INSERT INTO forecast_versions (
    id,
    label,
    status,
    period_year,
    period_month,
    fc_horizon_months,
    source_version_id,
    created_by
) VALUES (
    gen_random_uuid(),
    sqlc.arg(label),
    'working',
    sqlc.arg(period_year),
    sqlc.arg(period_month),
    sqlc.arg(fc_horizon_months),
    sqlc.narg(source_version_id),
    sqlc.arg(created_by)
)
RETURNING *;


-- name: ArchiveForecastVersion :one
-- Transitions the working version to archived.
-- The chk_fv_archived_consistency constraint guarantees that archived_at
-- and archived_by are either both set or both NULL — this UPDATE sets both.
-- Returns the updated row so the caller can record the new archived_at.
--
-- The WHERE status = 'working' guard prevents accidental double-archiving.
UPDATE forecast_versions
SET
    status      = 'archived',
    archived_at = now(),
    archived_by = sqlc.arg(archived_by)
WHERE  id     = sqlc.arg(id)
  AND  status = 'working'
RETURNING *;


-- name: GetVersionChain :many
-- Walks the source_version_id singly-linked list from a given version
-- back to the root (source_version_id IS NULL).
-- Returns versions oldest-last, i.e. position 1 = the requested version.
--
-- Use case: render the "version history" sidebar in the WebUI, or list
-- all archived snapshots available for a comparison.
--
-- PLAN: each recursive step hits idx_fc_versions_source with a single-key
-- lookup.  The chain is at most ~24 nodes for a 2-year rolling forecast,
-- so this is always fast.
--
-- PERFORMANCE NOTE (PG18)
-- MATERIALIZED is intentional: without it, PG12+ may try to inline the
-- recursive CTE into the outer query.  Inlining a recursive CTE is not
-- possible today, but the hint future-proofs the query against planner
-- changes and makes the intent explicit.
WITH RECURSIVE chain AS MATERIALIZED (
    -- Anchor: the requested start version
    SELECT
        fv.id,
        fv.label,
        fv.status,
        fv.period_year,
        fv.period_month,
        fv.source_version_id,
        fv.archived_at,
        1 AS position
    FROM  forecast_versions fv
    WHERE fv.id = sqlc.arg(start_version_id)

    UNION ALL

    -- Recursion: follow source_version_id until NULL
    SELECT
        fv.id,
        fv.label,
        fv.status,
        fv.period_year,
        fv.period_month,
        fv.source_version_id,
        fv.archived_at,
        c.position + 1
    FROM  forecast_versions fv
    JOIN  chain             c ON c.source_version_id = fv.id
)
SELECT id, label, status, period_year, period_month, archived_at, position
FROM   chain
ORDER  BY position;
