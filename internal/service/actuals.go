package service

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"
	"github.com/yourorg/workforce-planning/internal/db"
)

// ActualsService manages SAP import runs and employee_actuals ingestion.
type ActualsService struct {
	pool *pgxpool.Pool
}

// NewActualsService creates an ActualsService backed by the given pool.
func NewActualsService(pool *pgxpool.Pool) *ActualsService {
	return &ActualsService{pool: pool}
}

// ImportRow represents one employee record from a SAP export file.
type ImportRow struct {
	EmployeeID       uuid.UUID
	FirstName        string
	LastName         string
	CostcenterID     uuid.UUID
	ClassificationID *uuid.UUID
	EmployeeGroupID  *uuid.UUID
	JobDescription   *string
	FTE              decimal.Decimal
}

// RunImport creates an import_run record and bulk-inserts all rows using pgx CopyFrom.
// CopyFrom is orders of magnitude faster than individual INSERTs for large files.
//
// Duplicate detection: if an import run already exists for the given period,
// an error is returned — the caller should inform the user to confirm an overwrite.
func (s *ActualsService) RunImport(ctx context.Context, importedBy uuid.UUID, periodYear, periodMonth int16, sourceFile *string, rows []ImportRow) (db.ImportRun, error) {
	q := db.New(s.pool)

	// Guard against duplicate import for the same period.
	_, err := q.GetImportRunByPeriod(ctx, db.GetImportRunByPeriodParams{
		PeriodYear:  periodYear,
		PeriodMonth: periodMonth,
	})
	if err == nil {
		return db.ImportRun{}, fmt.Errorf("import run for %d-%02d already exists", periodYear, periodMonth)
	}

	// Create the import_run header row.
	run, err := q.InsertImportRun(ctx, db.InsertImportRunParams{
		PeriodYear:  periodYear,
		PeriodMonth: periodMonth,
		SourceFile:  sourceFile,
		ImportedBy:  importedBy,
	})
	if err != nil {
		return db.ImportRun{}, fmt.Errorf("insert import run: %w", err)
	}

	// Bulk insert via CopyFrom — far faster than per-row INSERT for thousands of records.
	copyRows := make([][]any, len(rows))
	for i, r := range rows {
		copyRows[i] = []any{
			uuid.New(),                       // id
			run.ID,                           // import_run_id
			r.EmployeeID,                     // employee_id (uuid.UUID, non-null)
			r.FirstName,                      // first_name
			r.LastName,                       // last_name
			r.CostcenterID,                   // costcenter_id (uuid.UUID, non-null)
			toNullUUIDPtr(r.ClassificationID), // classification_id (uuid.NullUUID)
			toNullUUIDPtr(r.EmployeeGroupID),  // employee_group_id (uuid.NullUUID)
			r.JobDescription,                 // job_description
			r.FTE,                            // fte
		}
	}

	cols := []string{"id", "import_run_id", "employee_id", "first_name", "last_name",
		"costcenter_id", "classification_id", "employee_group_id", "job_description", "fte"}

	n, err := s.pool.CopyFrom(ctx,
		pgx.Identifier{"employee_actuals"},
		cols,
		pgx.CopyFromRows(copyRows),
	)
	if err != nil {
		return db.ImportRun{}, fmt.Errorf("bulk insert employee actuals: %w", err)
	}

	// Record the final row count on the import_run.
	rowCount := int32(n)
	if err := q.UpdateImportRunRowCount(ctx, db.UpdateImportRunRowCountParams{
		ID:       run.ID,
		RowCount: &rowCount,
	}); err != nil {
		return db.ImportRun{}, fmt.Errorf("update row count: %w", err)
	}

	return q.GetImportRunByID(ctx, run.ID)
}

// GetLatestImportRun returns the most recent completed import run.
func (s *ActualsService) GetLatestImportRun(ctx context.Context) (db.GetLatestCompletedImportRunRow, error) {
	return db.New(s.pool).GetLatestCompletedImportRun(ctx)
}

// ListImportRuns returns all import runs, newest first.
func (s *ActualsService) ListImportRuns(ctx context.Context) ([]db.ListImportRunsRow, error) {
	return db.New(s.pool).ListImportRuns(ctx)
}

// GetActualsForEmployee returns the full actuals history for one employee.
func (s *ActualsService) GetActualsForEmployee(ctx context.Context, employeeID uuid.UUID) ([]db.GetActualsForEmployeeRow, error) {
	return db.New(s.pool).GetActualsForEmployee(ctx, employeeID)
}
