-- ============================================================
-- queries/lookups.sql
-- Lookup tables: classification_types, employee_groups, system_config
-- ============================================================


-- name: ListClassificationTypes :many
-- Returns all active classification types ordered for UI display.
-- Result is small (< 20 rows) — no index needed beyond the PK.
SELECT id, code, label, sort_order
FROM   classification_types
WHERE  is_active = true
ORDER  BY sort_order, label;


-- name: ListEmployeeGroups :many
-- Returns all active employee groups ordered for UI display.
SELECT id, code, label, sort_order
FROM   employee_groups
WHERE  is_active = true
ORDER  BY sort_order, label;


-- name: GetSystemConfigValue :one
-- Fetches a single config value by key.
-- Cast to the required type in the application layer.
SELECT value
FROM   system_config
WHERE  key = sqlc.arg(key);


-- name: UpsertSystemConfig :exec
-- Creates or updates a config entry.
-- updated_by may be NULL for system-level changes (e.g. initial seed).
INSERT INTO system_config (key, value, description, updated_by, updated_at)
VALUES (
    sqlc.arg(key),
    sqlc.arg(value),
    sqlc.narg(description),
    sqlc.narg(updated_by),
    now()
)
ON CONFLICT (key) DO UPDATE
    SET value      = EXCLUDED.value,
        updated_by = EXCLUDED.updated_by,
        updated_at = now();
