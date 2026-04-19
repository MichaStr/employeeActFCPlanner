# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

PostgreSQL workforce planning application. Holds monthly SAP actual employee data (immutable) and a rolling 18-month headcount forecast with version control, temporal change tracking, and full audit trail. Exposed via a REST API (chi) and a CLI tool (Cobra).

## Repository layout

```
workforceDbSchema/
├── cmd/
│   ├── cli/main.go          — wfp CLI entry point
│   └── server/main.go       — HTTP server entry point
├── internal/
│   ├── config/              — Config struct + Load() from env
│   ├── service/             — Business logic (forecast, actuals, reporting)
│   ├── api/                 — chi router, handlers, middleware
│   └── cli/                 — Cobra subcommands (import, rollover, version)
├── internal/db/             — sqlc-generated (DO NOT EDIT)
├── sql/
│   ├── migrations/          — Goose SQL files 001–004
│   └── queries/             — sqlc-annotated SQL files
├── docs/
│   ├── sqlc-usage.md        — Generated Go function reference
│   └── cli-usage.md         — CLI command reference
├── web/dist/                — Frontend assets (gitignored, compiled by npm)
├── workforce_planning.dbml  — Schema source of truth (visualise on dbdiagram.io)
├── sqlc.yaml                — sqlc v2 config
└── Taskfile.yml             — Task runner (replaces make)
```

## Development commands

```sh
# Task runner — install once:  go install github.com/go-task/task/v3/cmd/task@latest
task build          # compile → bin/wfp-cli + bin/wfp-server
task run-server     # go run ./cmd/server   (needs DATABASE_URL)
task run-cli        # go run ./cmd/cli      (append -- <subcommand>)

# Database
task migrate-up     # goose up   (needs DATABASE_URL)
task migrate-status # goose status

# Code generation — run after ANY change to sql/queries/ or sql/migrations/
task sqlc-gen       # regenerates internal/db/

# Quality
task test           # go test ./...
task vet            # go vet ./...
task tidy           # go mod tidy
```

**Required environment variable** for every CLI and server command:
```sh
export DATABASE_URL="postgres://user:password@host:5432/dbname?sslmode=disable"
```

## Go module

Module path: `github.com/yourorg/workforce-planning`  
(Change to your real GitHub org/user before pushing.)

Key dependencies: `pgx/v5`, `go-chi/chi/v5`, `spf13/cobra`, `google/uuid`, `shopspring/decimal`.

## Schema file

`workforce_planning.dbml` is the single source of truth for table definitions. Paste it into **dbdiagram.io** to visualise. Goose migrations are the authoritative SQL; DBML is the design reference.

## Domain model

### Two data tracks

**Actuals track** (immutable after import)
- `import_runs` — one row per monthly SAP batch, unique on `(period_year, period_month)`
- `employee_actuals` — full attribute snapshot per employee per import; never updated or deleted

**Forecast track** (versioned, temporal)
- `forecast_versions` — one `working` version at a time + unlimited `archived` monthly snapshots
- `forecast_entries` — SCD Type 2; each row stores a full attribute state valid between `valid_from` and `valid_to` (always first-of-month dates)
- `forecast_entry_audit` — append-only JSONB diff log; one row per write on `forecast_entries`

### Employee subjects

Every `forecast_entries` row references **exactly one** of:
- `employee_id` → `employees` (real SAP personnel, identity-only)
- `container_id` → `planning_containers` (virtual HC buckets; can carry negative or >1 FTE)

Enforced by a `CHECK` constraint in migration 001.

### Costcenter hierarchy

`costcenters` is self-referential via `parent_id`. Three levels: division (1) → department (2) → costcenter (3). Walk with `WITH RECURSIVE`.

### Forecast version lifecycle

1. First version: `CreateInitialVersion` → `source_version_id = NULL`
2. Month-end: `ArchiveAndSeed` (atomically archives working + creates new working + seeds entries)
3. `source_version_id` forms a singly-linked list — walk with `GetVersionChain`

## Service layer patterns

All service methods that write to `forecast_entries` must go through `withAuditTx`:

```go
func (s *ForecastService) withAuditTx(ctx context.Context, userID uuid.UUID, fn func(*db.Queries) error) error {
    tx, _ := s.pool.Begin(ctx)
    defer tx.Rollback(ctx)
    tx.Exec(ctx, "SET LOCAL app.current_user_id = $1", userID.String()) // required by audit trigger
    fn(db.New(tx))   // all writes inside fn are audited
    tx.Commit(ctx)
}
```

**SCD Type 2 write pattern** (always a two-step operation):
```go
// Step 1 — close the current open row
q.CloseEmployeeForecastEntry(ctx, CloseEmployeeForecastEntryParams{
    VersionID: ..., EmployeeID: ..., ValidTo: timeToDate(changeMonth),
})
// Step 2 — insert new open-ended row
q.InsertForecastEntry(ctx, InsertForecastEntryParams{
    ..., ValidFrom: timeToDate(changeMonth), // valid_to omitted → NULL
})
```

## sqlc type overrides

| PostgreSQL type | Go type | Notes |
|---|---|---|
| `uuid` (non-null) | `uuid.UUID` | pgx v5 handles natively |
| `uuid` (nullable) | `uuid.NullUUID` | pgx v5 falls back to `sql.Scanner` |
| `pg_catalog.numeric` | `decimal.Decimal` | Register pgxdecimal codec at startup — see `cmd/server/main.go` |
| `jsonb` | `json.RawMessage` | Unmarshal only when needed |

Helper functions in `internal/service/forecast.go`:
```go
toNullUUID(id uuid.UUID) uuid.NullUUID          // non-null → NullUUID
toNullUUIDPtr(id *uuid.UUID) uuid.NullUUID      // pointer → NullUUID (nil → not valid)
timeToDate(t time.Time) pgtype.Date             // time → pgtype.Date
```

## HTTP API (current state)

Router: `internal/api/router.go` (chi).  
Auth: `internal/api/middleware/auth.go` reads `X-User-ID` header as UUID — **replace with JWT in production**.

Routes:
```
GET  /healthz
GET  /api/versions               → list all versions
POST /api/versions               → create initial version
GET  /api/versions/{id}          → get version by ID (stub)
POST /api/versions/{id}/archive  → rollover (ArchiveAndSeed)
GET  /api/versions/{id}/chain    → version history (stub)
POST /api/versions/{id}/entries  → SCD write for employee
DELETE /api/versions/{id}/entries/{entryID}  → soft delete
GET  /api/versions/{id}/entries/{entryID}/history  → audit log (stub)
GET  /api/versions/{id}/rollup   → monthly CC rollup (?start=&end=)
GET  /api/diff/cc                → FTE diff between versions (?version_a=&version_b=&month=)
GET  /api/diff/employee          → row-level diff (?version_a=&version_b=&month=)
POST /api/import                 → run SAP import
GET  /api/import                 → list import runs
GET  /api/import/{id}            → get import run (stub)
GET  /api/import/{id}/rollup     → actuals rollup by CC
GET  /api/import/diff            → MoM delta (?prev=&curr=)
GET  /api/costcenters            → flat active list
GET  /api/costcenters/tree       → full hierarchy
GET  /api/costcenters/{id}       → by ID
GET  /api/costcenters/{id}/descendants → subtree
```

Handlers marked **stub** return `{"status":"not implemented"}` — implement by calling the relevant service/db method and responding with JSON.

## CLI commands

See `docs/cli-usage.md` for the full reference. Quick summary:

```sh
wfp import   --year 2025 --month 7 --file export.xlsx --user <uuid>
wfp rollover --label "2025-08" --year 2025 --month 8 --user <uuid>
wfp version list
wfp version chain <version-uuid>
```

## Critical constraints (migration 001)

```sql
-- forecast_entries: exactly one subject
CHECK ((employee_id IS NOT NULL AND container_id IS NULL)
    OR (employee_id IS NULL     AND container_id IS NOT NULL))

-- valid_from must be first of month
CHECK (EXTRACT(DAY FROM valid_from) = 1)

-- soft-delete triple consistency
CHECK ((is_deleted = false AND deleted_by IS NULL  AND deleted_at IS NULL)
    OR (is_deleted = true  AND deleted_by IS NOT NULL AND deleted_at IS NOT NULL))

-- at most one working version
CREATE UNIQUE INDEX uq_fc_versions_one_working ON forecast_versions (status) WHERE status = 'working';
```

## Key query patterns

**Active forecast row for a subject in month M:**
```sql
WHERE version_id = $v
  AND valid_from <= $month_start
  AND (valid_to IS NULL OR valid_to > $month_start)
  AND is_deleted = false
```

**Monthly CC headcount rollup (WebUI table):**
Uses `CROSS JOIN LATERAL` over `generate_series` + index `(version_id, costcenter_id, valid_from) INCLUDE (valid_to, fte)`.

## Runtime configuration

Copy `.env.example` → `.env` and fill in your values.
`config.Load()` calls `godotenv.Load()` first; OS env vars always win over `.env`.

```sh
cp .env.example .env
# edit .env — set DATABASE_URL at minimum
```

| Env var | Required | Default | Description |
|---------|----------|---------|-------------|
| `DATABASE_URL` | yes | — | pgx connection string |
| `PORT` | no | `8080` | HTTP listen port |
| `LOG_LEVEL` | no | `info` | `debug` \| `info` \| `warn` \| `error` |
| `JWT_SECRET` | no | — | JWT signing secret (for future auth) |

`.env` is gitignored. `.env.example` is committed (template only, no secrets).
Application settings (e.g. `fc_horizon_months = 18`) are stored in the `system_config` table.
