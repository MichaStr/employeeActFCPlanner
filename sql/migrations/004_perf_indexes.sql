-- +goose Up

-- ============================================================
-- Performance index improvements for the forecast_entries table
--
-- WHY THIS MIGRATION EXISTS
-- ─────────────────────────
-- Migration 001 created three indexes on forecast_entries that are
-- correct but require heap fetches for the two most important queries:
--
--   1. Monthly CC rollup (WebUI table)
--        idx_fe_version_cc_from (version_id, costcenter_id, valid_from)
--        Missing: valid_to, fte
--        Effect:  every matched index row causes a heap fetch just to
--                 evaluate (valid_to IS NULL OR valid_to > month) and
--                 to read fte for the SUM.  Over 18 months × N employees
--                 this is the single biggest source of I/O in the schema.
--
--   2. Active-row lookup per employee / container
--        idx_fe_version_empl_from INCLUDE (valid_to)
--        idx_fe_version_cont_from INCLUDE (valid_to)
--        Missing: fte
--        Effect:  valid_to is already covered by INCLUDE so the temporal
--                 predicate is index-only, but fte still needs a heap fetch
--                 for any query that projects or aggregates FTE per subject.
--
-- APPROACH
-- ────────
-- We create replacement indexes with wider INCLUDE columns, then drop the
-- originals.  In production, run CREATE INDEX CONCURRENTLY first, verify,
-- then DROP INDEX CONCURRENTLY — the statements here are written for a
-- controlled migration window (not CONCURRENTLY) for simplicity.
--
-- POSTGRESQL 18 NOTE
-- ──────────────────
-- PG18 extended the async I/O subsystem which reduces the latency of heap
-- fetches significantly.  However, eliminating heap fetches entirely via
-- index-only scans is still a large win — async I/O amortises latency but
-- does not reduce the number of pages read.  These wider INCLUDE indexes
-- are additive to PG18 improvements.
-- ============================================================


-- ── 1. Monthly CC rollup index ────────────────────────────────────────────────
--
-- Original: (version_id, costcenter_id, valid_from) WHERE is_deleted = false
-- Replacement adds INCLUDE (valid_to, fte) so the rollup query becomes
-- fully index-only:
--   WHERE version_id = $v AND is_deleted = false AND valid_from <= $month
--   AND (valid_to IS NULL OR valid_to > $month)
--   → all four columns are now in the index leaf page.

DROP INDEX IF EXISTS idx_fe_version_cc_from;

CREATE INDEX idx_fe_version_cc_from
    ON forecast_entries (version_id, costcenter_id, valid_from)
    INCLUDE (valid_to, fte)
    WHERE is_deleted = false;

COMMENT ON INDEX idx_fe_version_cc_from IS
    'Covers the monthly CC rollup query entirely (index-only scan). '
    'Key: (version_id, costcenter_id, valid_from). Payload: valid_to + fte.';


-- ── 2. Active-row lookup per real employee ────────────────────────────────────
--
-- Adds fte to the existing INCLUDE set.

DROP INDEX IF EXISTS idx_fe_version_empl_from;

CREATE INDEX idx_fe_version_empl_from
    ON forecast_entries (version_id, employee_id, valid_from)
    INCLUDE (valid_to, fte, costcenter_id, classification_id, employee_group_id)
    WHERE is_deleted = false AND employee_id IS NOT NULL;

COMMENT ON INDEX idx_fe_version_empl_from IS
    'Active-row lookup per employee. INCLUDE covers fte + attribute FKs '
    'needed for single-row display and version diff without heap access.';


-- ── 3. Active-row lookup per planning container ───────────────────────────────

DROP INDEX IF EXISTS idx_fe_version_cont_from;

CREATE INDEX idx_fe_version_cont_from
    ON forecast_entries (version_id, container_id, valid_from)
    INCLUDE (valid_to, fte, costcenter_id, classification_id, employee_group_id)
    WHERE is_deleted = false AND container_id IS NOT NULL;

COMMENT ON INDEX idx_fe_version_cont_from IS
    'Active-row lookup per planning container. Same INCLUDE strategy as the '
    'employee variant.';


-- ── 4. Open-ended-rows-only partial index ─────────────────────────────────────
--
-- The SCD "close current row" UPDATE needs to find exactly one row per subject:
--   WHERE version_id = $v AND employee_id = $e AND valid_to IS NULL AND is_deleted = false
--
-- idx_fe_version_empl_from covers (version_id, employee_id, valid_from) but
-- the planner still has to check valid_to via INCLUDE for every valid_from value.
-- This dedicated partial index on valid_to IS NULL lets PostgreSQL find the single
-- open-ended row with a tiny single-key lookup — typical cost: 2-3 index pages.

CREATE INDEX idx_fe_version_empl_open
    ON forecast_entries (version_id, employee_id)
    WHERE valid_to IS NULL AND is_deleted = false AND employee_id IS NOT NULL;

CREATE INDEX idx_fe_version_cont_open
    ON forecast_entries (version_id, container_id)
    WHERE valid_to IS NULL AND is_deleted = false AND container_id IS NOT NULL;

COMMENT ON INDEX idx_fe_version_empl_open IS
    'Finds the single open-ended (valid_to IS NULL) row per employee per version. '
    'Used by the SCD close-row UPDATE.';

COMMENT ON INDEX idx_fe_version_cont_open IS
    'Same as idx_fe_version_empl_open but for planning containers.';


-- +goose Down

-- Restore the original 001 indexes.

DROP INDEX IF EXISTS idx_fe_version_cc_from;
DROP INDEX IF EXISTS idx_fe_version_empl_from;
DROP INDEX IF EXISTS idx_fe_version_cont_from;
DROP INDEX IF EXISTS idx_fe_version_empl_open;
DROP INDEX IF EXISTS idx_fe_version_cont_open;

CREATE INDEX idx_fe_version_cc_from
    ON forecast_entries (version_id, costcenter_id, valid_from)
    WHERE is_deleted = false;

CREATE INDEX idx_fe_version_empl_from
    ON forecast_entries (version_id, employee_id, valid_from)
    INCLUDE (valid_to)
    WHERE is_deleted = false AND employee_id IS NOT NULL;

CREATE INDEX idx_fe_version_cont_from
    ON forecast_entries (version_id, container_id, valid_from)
    INCLUDE (valid_to)
    WHERE is_deleted = false AND container_id IS NOT NULL;
