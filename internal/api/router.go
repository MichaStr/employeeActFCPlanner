package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/yourorg/workforce-planning/internal/api/handler"
	apimw "github.com/yourorg/workforce-planning/internal/api/middleware"
	"github.com/yourorg/workforce-planning/internal/service"
)

// NewRouter wires up all routes with their middleware stack.
// The pool is passed through to services so handlers share one connection pool.
func NewRouter(pool *pgxpool.Pool) http.Handler {
	forecastSvc := service.NewForecastService(pool)
	actualsSvc := service.NewActualsService(pool)
	reportingSvc := service.NewReportingService(pool)

	fh := handler.NewForecastHandler(forecastSvc, reportingSvc)
	ah := handler.NewActualsHandler(actualsSvc, reportingSvc)
	ch := handler.NewCostcenterHandler(pool)

	r := chi.NewRouter()

	// Global middleware — applied to every request.
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(apimw.Logger)
	r.Use(middleware.Recoverer)

	// Health check — no auth required.
	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok")) //nolint:errcheck
	})

	// API routes — require authentication.
	r.Group(func(r chi.Router) {
		r.Use(apimw.Authenticate)

		// Forecast versions
		r.Get("/api/versions", fh.ListVersions)
		r.Post("/api/versions", fh.CreateVersion)
		r.Get("/api/versions/{id}", fh.GetVersion)
		r.Post("/api/versions/{id}/archive", fh.ArchiveVersion)
		r.Get("/api/versions/{id}/chain", fh.GetVersionChain)

		// Forecast entries (within a version)
		r.Post("/api/versions/{id}/entries", fh.UpsertEmployeeEntry)
		r.Delete("/api/versions/{id}/entries/{entryID}", fh.DeleteEntry)
		r.Get("/api/versions/{id}/entries/{entryID}/history", fh.GetEntryHistory)

		// Reporting — monthly rollup (WebUI table)
		r.Get("/api/versions/{id}/rollup", fh.GetMonthlyRollup)

		// Diff between two versions
		r.Get("/api/diff/cc", fh.DiffByCC)
		r.Get("/api/diff/employee", fh.DiffByEmployee)

		// SAP actuals import & queries
		r.Post("/api/import", ah.RunImport)
		r.Get("/api/import", ah.ListImportRuns)
		r.Get("/api/import/{id}", ah.GetImportRun)
		r.Get("/api/import/{id}/rollup", ah.GetActualsRollup)
		r.Get("/api/import/diff", ah.GetMoMDelta)

		// Cost center hierarchy
		r.Get("/api/costcenters", ch.ListActive)
		r.Get("/api/costcenters/tree", ch.GetTree)
		r.Get("/api/costcenters/{id}", ch.GetByID)
		r.Get("/api/costcenters/{id}/descendants", ch.GetDescendants)
	})

	return r
}
