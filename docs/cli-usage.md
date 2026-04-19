# CLI Usage Guide — `wfp`

The `wfp` binary is the administrative command-line tool for the workforce planning database.
It handles SAP data imports, monthly forecast rollovers, and version inspection.

---

## Prerequisites

### 1. Build the binary

```sh
task build-cli
# binary written to: bin/wfp-cli

# or run without building:
go run ./cmd/cli <subcommand>
```

### 2. Set the database connection

Every subcommand needs a PostgreSQL connection.  
Supply it via environment variable or the persistent `--db` flag:

```sh
# Option A — environment variable (recommended)
export DATABASE_URL="postgres://user:password@localhost:5432/workforce_planning?sslmode=disable"
wfp version list

# Option B — per-command flag (overrides DATABASE_URL)
wfp --db "postgres://..." version list
```

> The server also reads `PORT` (default `8080`), `LOG_LEVEL` (default `info`),
> and `JWT_SECRET` from the environment, but these are not needed for the CLI.

---

## Global flags

These flags are available on every subcommand:

| Flag | Description |
|------|-------------|
| `--db <url>` | Database URL, overrides `DATABASE_URL` env var |
| `--help`, `-h` | Show help for the current command |

---

## Subcommands

### `wfp import`

Loads a monthly SAP headcount export into `employee_actuals`.

```
wfp import --year <int> --month <int> [--file <name>] --user <uuid>
```

| Flag | Required | Description |
|------|----------|-------------|
| `--year` | yes | Fiscal year, e.g. `2025` |
| `--month` | yes | Fiscal month 1–12, e.g. `7` |
| `--file` | no | Source file name stored on the `import_runs` record (informational) |
| `--user` | yes | UUID of the user performing the import |

**What it does**

1. Checks whether an import run for the given period already exists — returns an error if it does (prevents accidental duplicates).
2. Creates an `import_runs` header row with `status = 'completed'`.
3. Bulk-inserts all employee rows via pgx `CopyFrom` into `employee_actuals`.
4. Updates `import_runs.row_count` with the final count.
5. Prints `Import complete: run_id=<uuid> rows=<n>` on success.

**Note on row data**  
The `RunImport` function in `internal/service/actuals.go` accepts a `[]service.ImportRow` slice.
The current CLI stub passes an empty slice (`var rows []service.ImportRow`) — you must add a file
parser in `internal/cli/import.go:runImport` that reads the actual CSV/Excel/JSON export and
populates `rows` before calling `svc.RunImport`.

Each `service.ImportRow` has:
```go
type ImportRow struct {
    EmployeeID       uuid.UUID
    FirstName        string
    LastName         string
    CostcenterID     uuid.UUID
    ClassificationID *uuid.UUID   // nil if SAP did not supply
    EmployeeGroupID  *uuid.UUID   // nil if SAP did not supply
    JobDescription   *string
    FTE              decimal.Decimal
}
```

**Example**

```sh
export DATABASE_URL="postgres://localhost/workforce_planning"
wfp import \
  --year 2025 \
  --month 7 \
  --file export_2025_07.xlsx \
  --user a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

Output:
```
Import complete: run_id=550e8400-e29b-41d4-a716-446655440000 rows=1248
```

---

### `wfp rollover`

Archives the current working forecast version and creates a new one, seeded with the
active state from the archive.  Runs atomically in a single database transaction.

```
wfp rollover --label <string> --year <int> --month <int> [--horizon <int>] --user <uuid>
```

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--label` | yes | — | Label for the **new** working version, e.g. `"2025-08"` |
| `--year` | yes | — | Period year for the new version |
| `--month` | yes | — | Period month for the new version (1–12) |
| `--horizon` | no | `18` | Forecast horizon in months for the new version |
| `--user` | yes | — | UUID of the user performing the rollover |

**What it does (three steps, one transaction)**

1. **Archive** — sets the current working version to `status = 'archived'` and records `archived_at` + `archived_by`.
2. **Create** — inserts a new `forecast_versions` row with `status = 'working'` and `source_version_id` pointing to the just-archived snapshot, forming the version linked list.
3. **Seed** — copies every active entry (where `valid_from <= seed_month AND (valid_to IS NULL OR valid_to > seed_month) AND is_deleted = false`) from the archive into the new version with `valid_from = first day of new period` and `valid_to = NULL`.

If any step fails, the entire transaction rolls back — no partial state.

**Example — month-end July → August 2025**

```sh
wfp rollover \
  --label "2025-08" \
  --year 2025 \
  --month 8 \
  --horizon 18 \
  --user a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

Output:
```
Rollover complete: new version id=7f3d9a12-... label=2025-08
```

---

### `wfp version`

Inspection commands for forecast versions.  No writes.

#### `wfp version list`

Lists all forecast versions, newest first.

```sh
wfp version list
```

Output:
```
ID                                    Label                 Status    Period
550e8400-e29b-41d4-a716-446655440000  2025-08               working   2025-08
3f6a1b2c-d4e5-6789-abcd-0123456789ab  2025-07               archived  2025-07
1a2b3c4d-5e6f-7890-abcd-ef1234567890  2025-06               archived  2025-06
```

#### `wfp version chain <version-id>`

Walks the `source_version_id` linked list from the given version back to the very first one.
Useful for auditing the history of snapshots or finding a version to diff against.

```sh
wfp version chain 550e8400-e29b-41d4-a716-446655440000
```

Output (position 1 = the requested version, increasing = older):
```
#1    550e8400-e29b-41d4-a716-446655440000  2025-08               working   2025-08
#2    3f6a1b2c-d4e5-6789-abcd-0123456789ab  2025-07               archived  2025-07
#3    1a2b3c4d-5e6f-7890-abcd-ef1234567890  2025-06               archived  2025-06
```

---

## Development workflow

Use the Task runner (`task`) for common operations.  
Install: `go install github.com/go-task/task/v3/cmd/task@latest`

```sh
task --list          # show all available tasks

task build           # compile both binaries → bin/wfp-cli and bin/wfp-server
task run-server      # start HTTP server (reads DATABASE_URL + PORT)
task run-cli         # run CLI via go run (append -- <args>)

task migrate-up      # apply pending Goose migrations
task migrate-status  # show migration state
task sqlc-gen        # regenerate internal/db from sql/queries/

task test            # run all Go tests
task vet             # run go vet
task tidy            # go mod tidy
```

**Run a CLI subcommand via task:**

```sh
# task run-cli passes CLI_ARGS through to the binary
task run-cli -- version list
task run-cli -- rollover --label "2025-08" --year 2025 --month 8 --user <uuid>
```

---

## Error reference

| Error | Cause | Fix |
|-------|-------|-----|
| `DATABASE_URL environment variable is required` | `DATABASE_URL` not set and `--db` not supplied | Export `DATABASE_URL` or pass `--db` |
| `import run for 2025-07 already exists` | `GetImportRunByPeriod` found an existing row | Use a different period or delete the existing run manually |
| `get working version: no rows in result set` | No `working` version exists in `forecast_versions` | Create the first version via `CreateInitialVersion` (API or direct SQL) |
| `invalid --user UUID: …` | `--user` flag is not a valid UUID v4 string | Check the UUID format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `connect to database: …` | pgxpool could not connect | Check host, port, credentials, and SSL settings in `DATABASE_URL` |

---

## Audit trail

Every write executed by the CLI goes through `service.ForecastService.withAuditTx`, which:

1. Opens a transaction.
2. Executes `SET LOCAL app.current_user_id = '<userID>'`.
3. Runs the write queries.
4. Commits.

The PostgreSQL trigger `trg_forecast_entries_audit` fires on every INSERT/UPDATE/DELETE to
`forecast_entries` and writes a row to `forecast_entry_audit` with the user ID, timestamp,
action type, and a JSONB diff of changed fields.

This means every CLI operation (including the seed during rollover) is fully audited.

---

## Adding a new subcommand

1. Create `internal/cli/<name>.go` in package `cli`.
2. Define a `var <name>Cmd = &cobra.Command{...}`.
3. Register flags and call `rootCmd.AddCommand(<name>Cmd)` in `func init()`.
4. Implement `RunE` — open the pool with `openQueries(cmd)` or `pgxpool.New(...)`, call the relevant service method, print the result.

The file is auto-included in the build because all files in `internal/cli/` are in the same `cli` package.
