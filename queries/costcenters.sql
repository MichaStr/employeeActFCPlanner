-- ============================================================
-- queries/costcenters.sql
-- Hierarchy traversal and lookup queries for the costcenters table.
--
-- PERFORMANCE NOTE (PG18)
-- ───────────────────────
-- WITH RECURSIVE queries are executed as a work-table scan in PostgreSQL.
-- PG18 does not change the fundamental recursive CTE execution strategy,
-- but the improved statistics and parallel query infrastructure help when
-- the result set is large.
--
-- For the typical hierarchy depth (3 levels, < 500 nodes total) these
-- queries are fast regardless of PG version.  If the CC tree grows to
-- thousands of nodes, consider materialising the full ancestry path as a
-- ltree column (pg_catalog extension) to avoid recursion at query time.
-- ============================================================


-- name: GetCostcenterByID :one
SELECT id, code, name, level, parent_id, is_active
FROM   costcenters
WHERE  id = sqlc.arg(id);


-- name: GetCostcenterByCode :one
SELECT id, code, name, level, parent_id, is_active
FROM   costcenters
WHERE  code = sqlc.arg(code);


-- name: ListActiveCostcenters :many
-- Flat list of all active CCs ordered by level then code.
-- Used to populate dropdowns; no hierarchy traversal needed.
SELECT id, code, name, level, parent_id
FROM   costcenters
WHERE  is_active = true
ORDER  BY level, code;


-- name: GetCostcenterTree :many
-- Returns the full active hierarchy as a flat list, each row annotated
-- with its ancestor path so the UI can reconstruct the tree without a
-- second round-trip.
--
-- path_ids   — ordered UUID array from root to this node (inclusive)
-- path_names — parallel array of CC names, useful for breadcrumb display
-- depth      — 0-based nesting depth (root = 0)
--
-- PLAN: anchor scans costcenters on (parent_id IS NULL), then each
-- recursive step uses idx_costcenters_parent_id for a fast index lookup.
WITH RECURSIVE tree AS (
    -- Anchor: root nodes (no parent)
    SELECT
        id,
        code,
        name,
        level,
        parent_id,
        ARRAY[id]   AS path_ids,
        ARRAY[name] AS path_names,
        0           AS depth
    FROM costcenters
    WHERE parent_id IS NULL
      AND is_active  = true

    UNION ALL

    -- Recursion: children of the previously found set
    SELECT
        c.id,
        c.code,
        c.name,
        c.level,
        c.parent_id,
        t.path_ids   || c.id,
        t.path_names || c.name,
        t.depth + 1
    FROM costcenters  c
    JOIN tree         t ON t.id = c.parent_id
    WHERE c.is_active = true
)
SELECT
    id,
    code,
    name,
    level,
    parent_id,
    path_ids,
    path_names,
    depth
FROM  tree
ORDER BY path_names;   -- sorts naturally: parent names first, then children alphabetically


-- name: GetCostcenterDescendants :many
-- Returns all active descendants of root_id, including root_id itself.
-- Used to scope a report to a sub-tree (e.g. all CCs under a given department).
--
-- PLAN: one recursive scan starting from a single row; each step hits
-- idx_costcenters_parent_id.  For a 3-level tree this is at most 3 iterations.
WITH RECURSIVE descendants AS (
    SELECT id, code, name, level, parent_id
    FROM   costcenters
    WHERE  id        = sqlc.arg(root_id)
      AND  is_active = true

    UNION ALL

    SELECT c.id, c.code, c.name, c.level, c.parent_id
    FROM   costcenters  c
    JOIN   descendants  d ON d.id = c.parent_id
    WHERE  c.is_active  = true
)
SELECT id, code, name, level, parent_id
FROM   descendants
ORDER  BY level, code;
