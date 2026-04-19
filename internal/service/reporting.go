package service

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/yourorg/workforce-planning/internal/db"
)

// ReportingService provides read-only aggregation queries for the WebUI table.
type ReportingService struct {
	pool *pgxpool.Pool
}

// NewReportingService creates a ReportingService backed by the given pool.
func NewReportingService(pool *pgxpool.Pool) *ReportingService {
	return &ReportingService{pool: pool}
}

// GetMonthlyRollup returns total FTE and headcount per costcenter per month for a version.
// This drives the main WebUI table: rows = costcenters, columns = months.
func (s *ReportingService) GetMonthlyRollup(ctx context.Context, versionID uuid.UUID, startMonth, endMonth time.Time) ([]db.MonthlyForecastRollupByCCRow, error) {
	return db.New(s.pool).MonthlyForecastRollupByCC(ctx, db.MonthlyForecastRollupByCCParams{
		VersionID:    versionID,
		FcStartMonth: pgtype.Timestamptz{Time: startMonth, Valid: true},
		FcEndMonth:   pgtype.Timestamptz{Time: endMonth, Valid: true},
	})
}

// DiffVersionsByCC compares total FTE per costcenter between two versions for a given month.
// Returns only costcenters where values differ.
func (s *ReportingService) DiffVersionsByCC(ctx context.Context, versionAID, versionBID uuid.UUID, month time.Time) ([]db.DiffVersionsByCCRow, error) {
	return db.New(s.pool).DiffVersionsByCC(ctx, db.DiffVersionsByCCParams{
		VersionAID: versionAID,
		VersionBID: versionBID,
		MonthStart: timeToDate(month),
	})
}

// DiffVersionsByEmployee returns row-level attribute diffs between two versions for a month.
func (s *ReportingService) DiffVersionsByEmployee(ctx context.Context, versionAID, versionBID uuid.UUID, month time.Time) ([]db.DiffVersionsByEmployeeRow, error) {
	return db.New(s.pool).DiffVersionsByEmployee(ctx, db.DiffVersionsByEmployeeParams{
		VersionAID: versionAID,
		VersionBID: versionBID,
		MonthStart: timeToDate(month),
	})
}

// ActualsMoMDelta returns the month-over-month FTE delta per costcenter between two import runs.
func (s *ReportingService) ActualsMoMDelta(ctx context.Context, prevRunID, currRunID uuid.UUID) ([]db.ActualsMoMDeltaRow, error) {
	return db.New(s.pool).ActualsMoMDelta(ctx, db.ActualsMoMDeltaParams{
		PrevRunID: prevRunID,
		CurrRunID: currRunID,
	})
}

// ActualsRollupByCC returns FTE and headcount per costcenter for a single import run.
func (s *ReportingService) ActualsRollupByCC(ctx context.Context, importRunID uuid.UUID) ([]db.ActualsRollupByCCRow, error) {
	return db.New(s.pool).ActualsRollupByCC(ctx, importRunID)
}
