// Package service contains the business logic layer.
// It sits between the HTTP handlers / CLI commands and the sqlc-generated db layer.
// All multi-step operations are wrapped in a transaction using the WithTx pattern.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"
	"github.com/yourorg/workforce-planning/internal/db"
)

// ForecastService handles SCD Type 2 writes, version lifecycle, and month rollover.
type ForecastService struct {
	pool *pgxpool.Pool
}

// NewForecastService creates a ForecastService backed by the given pool.
func NewForecastService(pool *pgxpool.Pool) *ForecastService {
	return &ForecastService{pool: pool}
}

// EmployeeChangeParams contains the new attribute state for a real employee forecast entry.
type EmployeeChangeParams struct {
	VersionID        uuid.UUID
	EmployeeID       uuid.UUID
	FirstName        string
	LastName         string
	CostcenterID     uuid.UUID
	ClassificationID *uuid.UUID // nil if not provided
	EmployeeGroupID  *uuid.UUID // nil if not provided
	JobDescription   *string
	FTE              decimal.Decimal
	ValidFrom        time.Time // must be first-of-month
}

// ApplyEmployeeChange executes the SCD Type 2 two-step write for a real employee:
//  1. Close the currently open row (valid_to = validFrom). 0 rows = no prior row, ok.
//  2. Insert a new open-ended row with the new attribute state.
//
// userID is used by the audit trigger (SET LOCAL app.current_user_id).
func (s *ForecastService) ApplyEmployeeChange(ctx context.Context, userID uuid.UUID, p EmployeeChangeParams) (db.ForecastEntry, error) {
	var entry db.ForecastEntry
	err := s.withAuditTx(ctx, userID, func(q *db.Queries) error {
		// Step 1 — close the open row.
		_, err := q.CloseEmployeeForecastEntry(ctx, db.CloseEmployeeForecastEntryParams{
			VersionID:  p.VersionID,
			EmployeeID: toNullUUID(p.EmployeeID),
			ValidTo:    timeToDate(p.ValidFrom),
		})
		if err != nil {
			return fmt.Errorf("close employee entry: %w", err)
		}

		// Step 2 — insert the new state.
		entry, err = q.InsertForecastEntry(ctx, db.InsertForecastEntryParams{
			VersionID:        p.VersionID,
			EmployeeID:       toNullUUID(p.EmployeeID),
			FirstName:        p.FirstName,
			LastName:         p.LastName,
			CostcenterID:     p.CostcenterID,
			ClassificationID: toNullUUIDPtr(p.ClassificationID),
			EmployeeGroupID:  toNullUUIDPtr(p.EmployeeGroupID),
			JobDescription:   p.JobDescription,
			Fte:              p.FTE,
			ValidFrom:        timeToDate(p.ValidFrom),
			CreatedBy:        userID,
		})
		if err != nil {
			return fmt.Errorf("insert employee entry: %w", err)
		}
		return nil
	})
	return entry, err
}

// ContainerChangeParams mirrors EmployeeChangeParams for planning containers.
type ContainerChangeParams struct {
	VersionID        uuid.UUID
	ContainerID      uuid.UUID
	FirstName        string
	LastName         string
	CostcenterID     uuid.UUID
	ClassificationID *uuid.UUID
	EmployeeGroupID  *uuid.UUID
	JobDescription   *string
	FTE              decimal.Decimal
	ValidFrom        time.Time
}

// ApplyContainerChange is the same SCD two-step for a planning container.
func (s *ForecastService) ApplyContainerChange(ctx context.Context, userID uuid.UUID, p ContainerChangeParams) (db.ForecastEntry, error) {
	var entry db.ForecastEntry
	err := s.withAuditTx(ctx, userID, func(q *db.Queries) error {
		_, err := q.CloseContainerForecastEntry(ctx, db.CloseContainerForecastEntryParams{
			VersionID:   p.VersionID,
			ContainerID: toNullUUID(p.ContainerID),
			ValidTo:     timeToDate(p.ValidFrom),
		})
		if err != nil {
			return fmt.Errorf("close container entry: %w", err)
		}

		entry, err = q.InsertForecastEntry(ctx, db.InsertForecastEntryParams{
			VersionID:        p.VersionID,
			ContainerID:      toNullUUID(p.ContainerID),
			FirstName:        p.FirstName,
			LastName:         p.LastName,
			CostcenterID:     p.CostcenterID,
			ClassificationID: toNullUUIDPtr(p.ClassificationID),
			EmployeeGroupID:  toNullUUIDPtr(p.EmployeeGroupID),
			JobDescription:   p.JobDescription,
			Fte:              p.FTE,
			ValidFrom:        timeToDate(p.ValidFrom),
			CreatedBy:        userID,
		})
		if err != nil {
			return fmt.Errorf("insert container entry: %w", err)
		}
		return nil
	})
	return entry, err
}

// CreateInitialVersion creates the very first forecast version (source_version_id = NULL).
func (s *ForecastService) CreateInitialVersion(ctx context.Context, userID uuid.UUID, label string, periodYear, periodMonth, horizonMonths int16) (db.ForecastVersion, error) {
	return db.New(s.pool).InsertForecastVersion(ctx, db.InsertForecastVersionParams{
		Label:           label,
		PeriodYear:      periodYear,
		PeriodMonth:     periodMonth,
		FcHorizonMonths: horizonMonths,
		CreatedBy:       userID,
	})
}

// ArchiveAndSeed performs the month-end rollover in a single transaction:
//  1. Archives the current working version.
//  2. Creates a new working version pointing to the archived snapshot.
//  3. Seeds all active entries from the archive into the new version.
func (s *ForecastService) ArchiveAndSeed(ctx context.Context, userID uuid.UUID, newLabel string, newPeriodYear, newPeriodMonth, horizonMonths int16) (db.ForecastVersion, error) {
	var newVersion db.ForecastVersion
	err := s.withAuditTx(ctx, userID, func(q *db.Queries) error {
		// 1. Archive the working version.
		working, err := q.GetWorkingForecastVersion(ctx)
		if err != nil {
			return fmt.Errorf("get working version: %w", err)
		}
		archived, err := q.ArchiveForecastVersion(ctx, db.ArchiveForecastVersionParams{
			ID:         working.ID,
			ArchivedBy: toNullUUID(userID),
		})
		if err != nil {
			return fmt.Errorf("archive version: %w", err)
		}

		// 2. Create new working version.
		newVersion, err = q.InsertForecastVersion(ctx, db.InsertForecastVersionParams{
			Label:           newLabel,
			PeriodYear:      newPeriodYear,
			PeriodMonth:     newPeriodMonth,
			FcHorizonMonths: horizonMonths,
			SourceVersionID: toNullUUID(archived.ID),
			CreatedBy:       userID,
		})
		if err != nil {
			return fmt.Errorf("insert new version: %w", err)
		}

		// 3. Seed: copy all active entries into the new version.
		seedMonth := time.Date(int(newPeriodYear), time.Month(newPeriodMonth), 1, 0, 0, 0, 0, time.UTC)
		activeEntries, err := q.ListActiveEntriesForVersion(ctx, db.ListActiveEntriesForVersionParams{
			VersionID:  archived.ID,
			MonthStart: timeToDate(seedMonth),
		})
		if err != nil {
			return fmt.Errorf("list active entries: %w", err)
		}

		for _, e := range activeEntries {
			// Fields from ListActiveEntriesForVersionRow are already uuid.NullUUID —
			// pass them through directly.
			_, err = q.InsertForecastEntry(ctx, db.InsertForecastEntryParams{
				VersionID:        newVersion.ID,
				EmployeeID:       e.EmployeeID,
				ContainerID:      e.ContainerID,
				FirstName:        e.FirstName,
				LastName:         e.LastName,
				CostcenterID:     e.CostcenterID,
				ClassificationID: e.ClassificationID,
				EmployeeGroupID:  e.EmployeeGroupID,
				JobDescription:   e.JobDescription,
				Fte:              e.Fte,
				ValidFrom:        timeToDate(seedMonth),
				CreatedBy:        userID,
			})
			if err != nil {
				return fmt.Errorf("seed entry: %w", err)
			}
		}
		return nil
	})
	return newVersion, err
}

// SoftDeleteEmployee soft-deletes the open forecast entry for an employee.
func (s *ForecastService) SoftDeleteEmployee(ctx context.Context, userID uuid.UUID, versionID, employeeID uuid.UUID) error {
	return s.withAuditTx(ctx, userID, func(q *db.Queries) error {
		return q.SoftDeleteEmployeeForecastEntry(ctx, db.SoftDeleteEmployeeForecastEntryParams{
			VersionID:  versionID,
			EmployeeID: toNullUUID(employeeID),
			DeletedBy:  toNullUUID(userID),
		})
	})
}

// withAuditTx begins a transaction, sets app.current_user_id for the audit trigger,
// runs fn, and commits. Rolls back on any error.
func (s *ForecastService) withAuditTx(ctx context.Context, userID uuid.UUID, fn func(*db.Queries) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Required by fn_forecast_entries_audit trigger.
	if _, err := tx.Exec(ctx, "SET LOCAL app.current_user_id = $1", userID.String()); err != nil {
		return fmt.Errorf("set audit session variable: %w", err)
	}

	if err := fn(db.New(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ── Type conversion helpers ───────────────────────────────────────────────────

// toNullUUID wraps a non-null uuid.UUID as a uuid.NullUUID.
func toNullUUID(id uuid.UUID) uuid.NullUUID {
	return uuid.NullUUID{UUID: id, Valid: true}
}

// toNullUUIDPtr converts an optional *uuid.UUID to uuid.NullUUID (null if nil).
func toNullUUIDPtr(id *uuid.UUID) uuid.NullUUID {
	if id == nil {
		return uuid.NullUUID{}
	}
	return uuid.NullUUID{UUID: *id, Valid: true}
}

// timeToDate converts a time.Time to a pgtype.Date (date only, no time component).
func timeToDate(t time.Time) pgtype.Date {
	return pgtype.Date{Time: t, Valid: true}
}
