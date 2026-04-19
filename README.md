# Workforce Planning — Database Schema

PostgreSQL database schema for a headcount planning application. Combines monthly SAP actual data with a rolling 18-month forecast, full version control, and a complete audit trail.

## Overview

The schema covers two parallel data tracks:

| Track | Description |
|---|---|
| **Actuals** | Monthly SAP imports — immutable snapshots, one per employee per month |
| **Forecast** | Rolling 18-month plan — versioned, temporal (SCD Type 2), with soft-delete and audit |

A **working forecast** is always open for editing. At month-end it is archived as a read-only snapshot and a new working version is seeded from it. This produces a linked chain of monthly snapshots that can be diffed against each other.

## Schema file

```
workforce_planning.dbml
```

Written in [DBML](https://dbml.dbdiagram.io/docs/). Open it on [dbdiagram.io](https://dbdiagram.io) to render the full ER diagram.

The DBML is the source of truth for:
- Table and column definitions
- Foreign key relationships
- Index annotations
- Notes on `CHECK` constraints and the partial unique index that must be added in the first Goose migration (DBML cannot express these natively)

## Tables

```
Lookup / reference
  costcenters          Self-referential hierarchy: division → department → costcenter
  employee_groups      Lookup for the empl_group field
  classification_types Extensible direct/indirect axis (direct, indirect, overhead, contractor, …)

Users & config
  users                Planners, admins, readers — referenced by all audit FK columns
  system_config        Runtime key/value settings (fc_horizon_months, fc_lock_day, …)

Employee identity
  employees            SAP identity anchor — employee_id (Personalnummer) only; never mutated
  planning_containers  Virtual HC buckets (empl_plan_no); can carry negative or >1 FTE

Actuals
  import_runs          One row per monthly SAP batch, unique on (period_year, period_month)
  employee_actuals     Full attribute snapshot per employee per import; immutable after insert

Forecast
  forecast_versions    Version registry — one working + unlimited archived monthly snapshots
  forecast_entries     SCD Type 2 rows: full state + valid_from / valid_to (first-of-month)
  forecast_entry_audit Append-only JSONB diff log; one row per write on forecast_entries
```

## Key design decisions

### Actuals are immutable
`employee_actuals` rows are never updated or deleted after insert. Every historical month is always fully reconstructable. Re-importing a month requires an explicit admin operation to delete the prior `import_run` first.

### Forecast uses SCD Type 2
Each change to a planned employee attribute closes the current open-ended row (`valid_to = change_month`) and inserts a new row (`valid_to = NULL`). This means any past state of any forecast version can be reconstructed with a simple date-range query:

```sql
WHERE version_id = $v
  AND valid_from <= $month_start
  AND (valid_to IS NULL OR valid_to > $month_start)
  AND is_deleted = false
```

### One working forecast at a time
Enforced by a partial unique index (`WHERE status = 'working'`). At month-end the working version is archived and a new one is seeded by copying all currently open-ended entries from the snapshot.

### Version lineage
`forecast_versions.source_version_id` is a self-FK that forms a singly-linked list:

```
working_v4 → snapshot_2025-03 → snapshot_2025-02 → snapshot_2025-01
```

Walk this chain to diff any two versions without extra tables.

### Planning containers
Virtual employees (`planning_containers`) have no SAP origin. They carry an `empl_plan_no` and can hold:
- **Positive FTE** — planned headcount addition
- **Negative FTE** — planned headcount reduction
- **FTE > 1** — multi-head bucket (e.g. plan 3 hires in one container)

Every `forecast_entries` row references exactly one real employee (`employee_id`) **or** one planning container (`container_id`), enforced by a `CHECK` constraint.

### Extensible classification
`direct_indirect` maps to the `classification_types` lookup table rather than a PostgreSQL `ENUM`. Adding a new category (e.g. `intern`) is a single `INSERT` — no `ALTER TYPE` migration needed.

## Constraints not in DBML

These must be added manually in the first Goose migration:

```sql
-- forecast_entries: exactly one subject
CHECK ((employee_id IS NOT NULL AND container_id IS NULL)
    OR (employee_id IS NULL     AND container_id IS NOT NULL))

-- forecast_entries: temporal sanity
CHECK (valid_to IS NULL OR valid_to > valid_from)

-- forecast_entries: valid_from must be first-of-month
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

## Repository structure

```
sql/
  migrations/
    001_initial_schema.sql   All tables, FK constraints, CHECK constraints, indexes
    002_seed_lookups.sql     Seed data: classification_types, employee_groups, system_config
    003_audit_trigger.sql    PL/pgSQL AFTER trigger that writes to forecast_entry_audit
    004_perf_indexes.sql     Wider INCLUDE indexes for index-only scans (PG18 optimised)
    goose_info.md            Goose CLI usage examples

  queries/
    lookups.sql              classification_types, employee_groups, system_config
    costcenters.sql          Hierarchy traversal (WITH RECURSIVE)
    actuals.sql              Import runs, actuals rollup, MoM delta
    forecast_versions.sql    Version lifecycle: create, archive, chain walk
    forecast_entries.sql     SCD Type 2 ops, monthly CC rollup, version diff
    sqlc_info.md             sqlc CLI usage examples

docs/
  sqlc-usage.md             How to use the sqlc-generated Go functions

internal/db/               Generated by sqlc — do not edit manually
workforce_planning.dbml    DBML schema source of truth
sqlc.yaml                  sqlc v2 config — pgx/v5 driver, uuid + decimal overrides
```

## Running migrations

```sh
# From the project root — apply all pending migrations
goose -dir sql/migrations postgres "postgres://<user>:<password>@<host>:<port>/<db>?sslmode=disable" up

# Roll back the last migration
goose -dir sql/migrations postgres "postgres://<user>:<password>@<host>:<port>/<db>?sslmode=disable" down
```

## Generating Go code

```sh
# From the project root (where sqlc.yaml lives)
sqlc generate
```

Generated files land in `internal/db/`. Never edit them manually — re-run `sqlc generate` after any query change.

## Toolchain

| Tool | Purpose |
|---|---|
| [Goose](https://github.com/pressly/goose) | SQL schema migrations |
| [sqlc](https://sqlc.dev) | Type-safe Go code generation from SQL |
| [pgx/v5](https://github.com/jackc/pgx) | PostgreSQL driver |
| [dbdiagram.io](https://dbdiagram.io) | ER diagram visualization from DBML |

See [`docs/sqlc-usage.md`](docs/sqlc-usage.md) for how to wire up the connection pool, register type codecs, and use every generated query function.
