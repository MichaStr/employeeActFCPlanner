# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

PostgreSQL workforce planning database. Holds monthly SAP actual employee data (immutable) and a rolling 18-month headcount forecast with version control, temporal change tracking, and full audit trail.

## Schema file

`workforce_planning.dbml` is the single source of truth for the schema design. It is written in [DBML](https://dbml.dbdiagram.io/docs/) and can be:
- Visualized at **dbdiagram.io** (paste or import the file)
- Used as a reference when writing Goose SQL migrations
- Used as a reference when writing sqlc query annotations

## Toolchain

| Tool | Purpose | Location |
|---|---|---|
| **Goose** | SQL migrations | `sql/migrations/` |
| **sqlc** | Go code generation | config: `sqlc.yaml`, queries: `sql/queries/` |
| **pgx/v5** | PostgreSQL driver | generated output: `internal/db/` |

```sh
# Apply migrations
goose -dir sql/migrations postgres "<conn>" up

# Regenerate Go DB layer (run after any query change)
sqlc generate
```

The first migration (`001_initial_schema.sql`) includes all `CHECK` constraints and the partial unique index that are noted at the top of `workforce_planning.dbml` but cannot be expressed in DBML itself.

## Domain model

### Two data tracks

**Actuals track** (immutable after import)
- `import_runs` — one row per monthly SAP batch, unique on `(period_year, period_month)`
- `employee_actuals` — full attribute snapshot per employee per import; never updated or deleted

**Forecast track** (versioned, temporal)
- `forecast_versions` — one `working` version at a time + unlimited `archived` monthly snapshots
- `forecast_entries` — SCD Type 2 rows; each row stores a full attribute state valid between `valid_from` and `valid_to` (always first-of-month dates)
- `forecast_entry_audit` — append-only JSONB diff log; one row per write on `forecast_entries`

### Employee subjects

Every `forecast_entries` row references **exactly one** of:
- `employee_id` → `employees` (real SAP personnel, identity-only table with `employee_id` / SAP number)
- `container_id` → `planning_containers` (virtual HC buckets, `empl_plan_no`; can carry negative or >1 FTE)

This exclusivity is enforced by a `CHECK` constraint in the migration (not expressible in DBML).

### Costcenter hierarchy

`costcenters` is self-referential via `parent_id`. Three levels by convention: division (1) → department (2) → costcenter (3). Walk with `WITH RECURSIVE`.

### Forecast version lifecycle

1. First version: `INSERT status='working', source_version_id=NULL`
2. Month-end: set `status='archived'`, `archived_at`, `archived_by`
3. New working FC: `INSERT status='working', source_version_id=<just-archived id>`; seed `forecast_entries` by copying open-ended rows from the prior snapshot
4. Repeat monthly

`source_version_id` is a self-FK forming a linked list — walk it to diff any two versions.

## Critical constraints (add in first migration)

```sql
-- forecast_entries: exactly one subject
CHECK ((employee_id IS NOT NULL AND container_id IS NULL)
    OR (employee_id IS NULL     AND container_id IS NOT NULL))

-- forecast_entries: temporal sanity
CHECK (valid_to IS NULL OR valid_to > valid_from)

-- forecast_entries: valid_from must be first of month
CHECK (EXTRACT(DAY FROM valid_from) = 1)

-- forecast_entries: soft-delete triple consistency
CHECK ((is_deleted = false AND deleted_by IS NULL  AND deleted_at IS NULL)
    OR (is_deleted = true  AND deleted_by IS NOT NULL AND deleted_at IS NOT NULL))

-- forecast_versions: at most one working version
CREATE UNIQUE INDEX uq_fc_versions_one_working
  ON forecast_versions (status) WHERE status = 'working';

-- forecast_versions: archived fields match status
CHECK ((status = 'archived' AND archived_at IS NOT NULL AND archived_by IS NOT NULL)
    OR (status = 'working'  AND archived_at IS NULL     AND archived_by IS NULL))
```

## Key query patterns

**Active forecast row for a subject in month M:**
```sql
WHERE version_id = $v
  AND valid_from <= $month_start
  AND (valid_to IS NULL OR valid_to > $month_start)
  AND is_deleted = false
```

**Monthly CC headcount rollup (WebUI table — most critical query):**
Uses index `(version_id, costcenter_id, valid_from)` on `forecast_entries` with `is_deleted = false`.

**Compare two forecast versions:** `FULL OUTER JOIN` on `COALESCE(employee_id::text, container_id::text)` filtered to the same target month.

**Compare two actuals months:** Join `employee_actuals` for two different `import_run_id` values.

## Configuration

Runtime settings live in `system_config` (key/value). Key: `fc_horizon_months` (default `18`).
