# Using the sqlc-generated Go DB layer

## Overview

Running `sqlc generate` from the project root produces a Go package in `internal/db/`.  
The package name is `db` and it targets `pgx/v5`.

Every SQL file in `sql/queries/` becomes a set of methods on `*db.Queries`.  
Each `-- name: Foo :one/:many/:exec` annotation generates:

| Annotation | Return type | Use for |
|---|---|---|
| `:one` | `(Row, error)` | Expect exactly one row |
| `:many` | `([]Row, error)` | Any number of rows |
| `:exec` | `error` | No result needed |
| `:execrows` | `(int64, error)` | Need the affected-row count |

---

## 1. Setup — connection pool and type registration

The `sqlc.yaml` overrides three PostgreSQL types to Go types that require codec registration on the pgx connection pool. Do this **once at startup**, before `db.New()`.

```go
package main

import (
    "context"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
    pgxdecimal "github.com/jackc/pgx-shopspring-decimal"
    pgxuuid    "github.com/vgarvardt/pgx-google-uuid/v5"

    "yourmodule/internal/db"
)

func newPool(ctx context.Context, connStr string) (*pgxpool.Pool, error) {
    cfg, err := pgxpool.ParseConfig(connStr)
    if err != nil {
        return nil, err
    }

    // Register custom type codecs on every new connection.
    // pgxuuid  → handles uuid  ↔ github.com/google/uuid.UUID
    // pgxdecimal → handles numeric ↔ github.com/shopspring/decimal.Decimal
    cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
        pgxuuid.Register(conn.TypeMap())
        pgxdecimal.Register(conn.TypeMap())
        return nil
    }

    return pgxpool.NewWithConfig(ctx, cfg)
}

func main() {
    ctx := context.Background()

    pool, err := newPool(ctx, "postgres://user:pass@localhost:5432/workforce?sslmode=disable")
    if err != nil {
        panic(err)
    }
    defer pool.Close()

    queries := db.New(pool)
    _ = queries // pass to your service layer
}
```

> **Why the codecs?**  
> `uuid` columns are overridden to `uuid.UUID` (not pgtype's `[16]byte` wrapper).  
> `numeric` columns are overridden to `decimal.Decimal` to avoid float64 rounding on FTE values.  
> Without `AfterConnect` registration, pgx will fail to encode/decode these types.

---

## 2. Audit session variable

The audit trigger (`003_audit_trigger.sql`) reads `app.current_user_id` from the PostgreSQL session to record who made each change. Set it at the start of every write transaction:

```go
func withAuditUser(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
    _, err := tx.Exec(ctx,
        "SET LOCAL app.current_user_id = $1", userID.String(),
    )
    return err
}
```

`SET LOCAL` scopes the variable to the current transaction and is automatically cleared when the transaction commits or rolls back — safe with connection pools.

---

## 3. Lookup tables

### List classification types (direct / indirect / …)

```go
types, err := queries.ListClassificationTypes(ctx)
// types []db.ListClassificationTypesRow
// fields: ID, Code, Label, SortOrder

for _, t := range types {
    fmt.Println(t.Code, t.Label) // "direct" "Direct"
}
```

### Read / write system config

```go
// Read fc_horizon_months
val, err := queries.GetSystemConfigValue(ctx, "fc_horizon_months")
months, _ := strconv.Atoi(val)

// Update at runtime
err = queries.UpsertSystemConfig(ctx, db.UpsertSystemConfigParams{
    Key:         "fc_horizon_months",
    Value:       "24",
    Description: pgtype.Text{String: "Extended to 24 months for 2026", Valid: true},
    UpdatedBy:   &userID,
})
```

---

## 4. Costcenter hierarchy

### Full tree (for a tree-picker UI component)

```go
nodes, err := queries.GetCostcenterTree(ctx)
// nodes []db.GetCostcenterTreeRow
// fields: ID, Code, Name, Level, ParentID, PathIDs, PathNames, Depth

// PathNames is []string from root → node, e.g. ["Engineering", "Backend", "Platform"]
for _, n := range nodes {
    indent := strings.Repeat("  ", n.Depth)
    fmt.Printf("%s%s (%s)\n", indent, n.Name, n.Code)
}
```

### Descendants of a single CC (e.g. sum FTE for a whole department)

```go
children, err := queries.GetCostcenterDescendants(ctx, departmentID)
// Use children[*].ID as a filter set in application-side logic
```

---

## 5. SAP import (actuals)

### Record a new import run

```go
run, err := queries.InsertImportRun(ctx, db.InsertImportRunParams{
    PeriodYear:  2025,
    PeriodMonth: 4,
    SourceFile:  pgtype.Text{String: "sap_export_2025_04.csv", Valid: true},
    ImportedBy:  importerUserID,
})
// run.ID is the UUID to pass to subsequent InsertEmployeeActual calls
```

### Bulk-insert actuals (prefer CopyFrom for production)

For large imports use pgx `CopyFrom` directly — it is far faster than row-by-row `INSERT` and bypasses per-row overhead. The `InsertEmployeeActual` query is suitable for small corrections only.

```go
// Production path — pgx CopyFrom
rows := make([][]any, 0, len(sapRecords))
for _, r := range sapRecords {
    rows = append(rows, []any{
        uuid.New(), run.ID, employeeUUID,
        r.FirstName, r.LastName,
        costcenterID, classificationID, employeeGroupID,
        r.JobDescription, r.FTE,
        time.Now(),
    })
}
_, err = pool.CopyFrom(ctx,
    pgx.Identifier{"employee_actuals"},
    []string{"id","import_run_id","employee_id","first_name","last_name",
              "costcenter_id","classification_id","employee_group_id",
              "job_description","fte","created_at"},
    pgx.CopyFromRows(rows),
)
```

### Month-over-month actuals delta

```go
prev, _  := queries.GetImportRunByPeriod(ctx, db.GetImportRunByPeriodParams{PeriodYear: 2025, PeriodMonth: 3})
curr, _  := queries.GetImportRunByPeriod(ctx, db.GetImportRunByPeriodParams{PeriodYear: 2025, PeriodMonth: 4})

deltas, err := queries.ActualsMoMDelta(ctx, db.ActualsMoMDeltaParams{
    PrevRunID: prev.ID,
    CurrRunID: curr.ID,
})
// deltas []db.ActualsMoMDeltaRow
// fields: CostcenterID, PrevFte *decimal.Decimal, CurrFte *decimal.Decimal, DeltaFte decimal.Decimal
```

---

## 6. Forecast version lifecycle

### Get or create the working version

```go
working, err := queries.GetWorkingForecastVersion(ctx)
if errors.Is(err, pgx.ErrNoRows) {
    // First run — no working version exists yet
    working, err = queries.InsertForecastVersion(ctx, db.InsertForecastVersionParams{
        Label:           "Working Forecast",
        PeriodYear:      2025,
        PeriodMonth:     4,
        FcHorizonMonths: 18,
        SourceVersionID: nil, // first version ever — no prior snapshot
        CreatedBy:       userID,
    })
}
```

### Month-end rollover (archive → seed new working version)

```go
func RolloverForecast(ctx context.Context, q *db.Queries, pool *pgxpool.Pool, userID uuid.UUID) error {
    tx, err := pool.Begin(ctx)
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx)

    qtx := q.WithTx(tx)

    // 1. Set audit user for trigger
    if err := withAuditUser(ctx, tx, userID); err != nil {
        return err
    }

    // 2. Archive the current working version
    old, err := qtx.ArchiveForecastVersion(ctx, db.ArchiveForecastVersionParams{
        ID:         working.ID,
        ArchivedBy: userID,
    })
    if err != nil {
        return err
    }

    // 3. Determine next period
    nextYear, nextMonth := old.PeriodYear, old.PeriodMonth+1
    if nextMonth > 12 {
        nextYear++
        nextMonth = 1
    }

    // 4. Create new working version seeded from the snapshot
    newVersion, err := qtx.InsertForecastVersion(ctx, db.InsertForecastVersionParams{
        Label:           fmt.Sprintf("Working Forecast %d-%02d", nextYear, nextMonth),
        PeriodYear:      nextYear,
        PeriodMonth:     nextMonth,
        FcHorizonMonths: old.FcHorizonMonths,
        SourceVersionID: &old.ID,
        CreatedBy:       userID,
    })
    if err != nil {
        return err
    }

    // 5. Copy open-ended entries from the snapshot into the new version
    //    (read all currently active rows from the old version and re-insert)
    activeRows, err := qtx.ListActiveEntriesForVersion(ctx, db.ListActiveEntriesForVersionParams{
        VersionID:  old.ID,
        MonthStart: time.Date(int(nextYear), time.Month(nextMonth), 1, 0, 0, 0, 0, time.UTC),
    })
    if err != nil {
        return err
    }

    for _, row := range activeRows {
        _, err = qtx.InsertForecastEntry(ctx, db.InsertForecastEntryParams{
            VersionID:        newVersion.ID,
            EmployeeID:       row.EmployeeID,
            ContainerID:      row.ContainerID,
            FirstName:        row.FirstName,
            LastName:         row.LastName,
            CostcenterID:     row.CostcenterID,
            ClassificationID: row.ClassificationID,
            EmployeeGroupID:  row.EmployeeGroupID,
            JobDescription:   row.JobDescription,
            Fte:              row.Fte,
            ValidFrom:        time.Date(int(nextYear), time.Month(nextMonth), 1, 0, 0, 0, 0, time.UTC),
            CreatedBy:        userID,
        })
        if err != nil {
            return err
        }
    }

    return tx.Commit(ctx)
}
```

### Browse the version chain

```go
chain, err := queries.GetVersionChain(ctx, workingVersionID)
// chain[0] = working version (position 1)
// chain[1] = previous snapshot (position 2)
// ...
for _, v := range chain {
    fmt.Printf("#%d  %s (%d-%02d)  status=%s\n",
        v.Position, v.Label, v.PeriodYear, v.PeriodMonth, v.Status)
}
```

---

## 7. Forecast entries — SCD Type 2 write pattern

Every attribute change is a **two-step transaction**: close the current open row, then insert the new state. Always wrap in a transaction so both steps succeed or both fail.

```go
func UpdateEmployeeForecastEntry(
    ctx    context.Context,
    q      *db.Queries,
    pool   *pgxpool.Pool,
    userID uuid.UUID,
    params UpdateParams,
) error {
    tx, err := pool.Begin(ctx)
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx)

    qtx := q.WithTx(tx)

    // Set audit user (picked up by the AFTER trigger)
    if err := withAuditUser(ctx, tx, userID); err != nil {
        return err
    }

    changeMonth := time.Date(params.Year, time.Month(params.Month), 1, 0, 0, 0, 0, time.UTC)

    // Step 1 — close the current open-ended row
    //          CloseEmployeeForecastEntry returns the number of rows updated.
    //          0 means no open row existed yet (first entry for this employee).
    rowsClosed, err := qtx.CloseEmployeeForecastEntry(ctx, db.CloseEmployeeForecastEntryParams{
        VersionID:  params.VersionID,
        EmployeeID: params.EmployeeID,
        ValidTo:    changeMonth,
    })
    if err != nil {
        return err
    }
    _ = rowsClosed // 0 = first entry, 1 = change to existing state

    // Step 2 — insert the new state (valid_to = NULL → open-ended)
    _, err = qtx.InsertForecastEntry(ctx, db.InsertForecastEntryParams{
        VersionID:        params.VersionID,
        EmployeeID:       &params.EmployeeID,
        ContainerID:      nil,
        FirstName:        params.FirstName,
        LastName:         params.LastName,
        CostcenterID:     params.CostcenterID,
        ClassificationID: params.ClassificationID,
        EmployeeGroupID:  params.EmployeeGroupID,
        JobDescription:   params.JobDescription,
        Fte:              params.FTE,
        ValidFrom:        changeMonth,
        CreatedBy:        userID,
    })
    if err != nil {
        return err
    }

    return tx.Commit(ctx)
}
```

> **Planning containers** use `CloseContainerForecastEntry` and `InsertForecastEntry` with `ContainerID` set instead of `EmployeeID`. The pattern is identical.

### Soft-delete a forecast entry

```go
tx, _ := pool.Begin(ctx)
defer tx.Rollback(ctx)
qtx := q.WithTx(tx)
withAuditUser(ctx, tx, userID)

err = qtx.SoftDeleteEmployeeForecastEntry(ctx, db.SoftDeleteEmployeeForecastEntryParams{
    VersionID:  versionID,
    EmployeeID: employeeID,
    DeletedBy:  userID,
})
tx.Commit(ctx)
// The audit trigger records action='DELETE' with the full row snapshot in changed_fields.
```

---

## 8. Monthly CC rollup (the WebUI table query)

This is the most performance-critical query. It drives the main table view: costcenters as rows, months as columns.

```go
now    := time.Now()
start  := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
end    := start.AddDate(0, 18, 0) // 18-month horizon

rows, err := queries.MonthlyForecastRollupByCC(ctx, db.MonthlyForecastRollupByCCParams{
    VersionID:     workingVersionID,
    FcStartMonth:  start,
    FcEndMonth:    end,
})
// rows []db.MonthlyForecastRollupByCCRow
// fields: MonthStart time.Time, CostcenterID uuid.UUID, TotalFte decimal.Decimal, Headcount int64

// Group into a map[costcenterID][monthStart]row for the WebUI grid
type Cell struct {
    TotalFte  decimal.Decimal
    Headcount int64
}
grid := make(map[uuid.UUID]map[time.Time]Cell)
for _, r := range rows {
    if grid[r.CostcenterID] == nil {
        grid[r.CostcenterID] = make(map[time.Time]Cell)
    }
    grid[r.CostcenterID][r.MonthStart] = Cell{r.TotalFte, r.Headcount}
}
```

---

## 9. Version comparison (diff)

### CC-level diff (summary)

```go
diff, err := queries.DiffVersionsByCC(ctx, db.DiffVersionsByCCParams{
    VersionAId: snapshotMarchID,
    VersionBId: workingVersionID,
    MonthStart: time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC),
})
// diff []db.DiffVersionsByCCRow
// Only CCs where FTE differs are returned.
// fields: CostcenterID, FteVersionA *decimal, FteVersionB *decimal, FteDelta decimal
```

### Employee-level diff (detailed)

```go
diff, err := queries.DiffVersionsByEmployee(ctx, db.DiffVersionsByEmployeeParams{
    VersionAId: snapshotMarchID,
    VersionBId: workingVersionID,
    MonthStart: time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC),
})
// diff []db.DiffVersionsByEmployeeRow
// Only subjects where any of FTE / costcenter / classification / group differ.
// Rows only in A have *_b columns nil (employee removed from FC in version B).
// Rows only in B have *_a columns nil (employee added to FC in version B).
for _, d := range diff {
    fmt.Printf("subject=%s  fte_a=%v  fte_b=%v  delta=%v\n",
        d.SubjectKey, d.FteA, d.FteB, d.FteDelta)
}
```

---

## 10. Audit log

### Change history for a single forecast entry

```go
history, err := queries.GetAuditHistoryForEntry(ctx, entryID)
// history []db.GetAuditHistoryForEntryRow
// fields: ID, Action, ChangedFields json.RawMessage, ChangedBy uuid, ChangedAt time.Time

// Decode the JSONB diff
type FieldChange struct {
    Old any `json:"old"`
    New any `json:"new"`
}
for _, h := range history {
    var diff map[string]FieldChange
    if h.ChangedFields != nil {
        json.Unmarshal(h.ChangedFields, &diff)
    }
    fmt.Printf("[%s] %s by %s\n", h.ChangedAt.Format(time.RFC3339), h.Action, h.ChangedBy)
    for field, change := range diff {
        fmt.Printf("  %s: %v → %v\n", field, change.Old, change.New)
    }
}
```

### Activity feed for a version

```go
activity, err := queries.GetAuditHistoryForVersion(ctx, db.GetAuditHistoryForVersionParams{
    VersionID:  workingVersionID,
    LimitRows:  50,
})
```

---

## 11. Transactions — `WithTx` pattern

All write operations that span multiple queries must run in a transaction. sqlc generates a `WithTx` method that returns a new `*Queries` scoped to the transaction:

```go
tx, err := pool.Begin(ctx)
if err != nil { ... }
defer tx.Rollback(ctx) // safe no-op after Commit

qtx := queries.WithTx(tx)
// use qtx for all queries inside the transaction
err = tx.Commit(ctx)
```

`WithTx` shares the same underlying interface (`db.DBTX`) so tests can pass a `*pgxpool.Pool` directly or a `pgx.Tx` without changing the function signatures.

---

## 12. Testing against a real database

sqlc generates a `Querier` interface (enabled by `emit_interface: true` in `sqlc.yaml`). Your service layer should accept `db.Querier` rather than `*db.Queries`:

```go
type ForecastService struct {
    q   db.Querier
    pool *pgxpool.Pool
}

func NewForecastService(pool *pgxpool.Pool) *ForecastService {
    return &ForecastService{q: db.New(pool), pool: pool}
}
```

In tests, spin up a real PostgreSQL database (e.g. via `testcontainers-go`), run the migrations with Goose, then pass a real `*pgxpool.Pool`. Do not mock the DB layer — the CHECK constraints, partial unique indexes, and triggers only fire against a real database.

```go
// Example test setup (testcontainers-go)
func TestMain(m *testing.M) {
    ctx := context.Background()
    pg, _ := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:18"),
        postgres.WithDatabase("workforce_test"),
    )
    connStr, _ := pg.ConnectionString(ctx, "sslmode=disable")
    goose.Up(openDB(connStr), "sql/migrations")
    pool, _ = newPool(ctx, connStr)
    os.Exit(m.Run())
}
```
