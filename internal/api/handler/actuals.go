package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	apimw "github.com/yourorg/workforce-planning/internal/api/middleware"
	"github.com/yourorg/workforce-planning/internal/service"
)

// ActualsHandler handles SAP import and actuals read endpoints.
type ActualsHandler struct {
	actuals   *service.ActualsService
	reporting *service.ReportingService
}

// NewActualsHandler creates an ActualsHandler.
func NewActualsHandler(actuals *service.ActualsService, reporting *service.ReportingService) *ActualsHandler {
	return &ActualsHandler{actuals: actuals, reporting: reporting}
}

// RunImport handles POST /api/import
// Body: {"period_year":2025,"period_month":7,"source_file":"export.xlsx","rows":[...]}
func (h *ActualsHandler) RunImport(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PeriodYear  int16                  `json:"period_year"`
		PeriodMonth int16                  `json:"period_month"`
		SourceFile  *string                `json:"source_file"`
		Rows        []service.ImportRow    `json:"rows"`
	}
	if !decodeBody(w, r, &req) {
		return
	}

	userID := apimw.UserIDFromContext(r.Context())
	run, err := h.actuals.RunImport(r.Context(), userID, req.PeriodYear, req.PeriodMonth, req.SourceFile, req.Rows)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, run)
}

// ListImportRuns handles GET /api/import
func (h *ActualsHandler) ListImportRuns(w http.ResponseWriter, r *http.Request) {
	runs, err := h.actuals.ListImportRuns(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, runs)
}

// GetImportRun handles GET /api/import/{id}
func (h *ActualsHandler) GetImportRun(w http.ResponseWriter, r *http.Request) {
	id, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}
	_ = id
	// TODO: call db.New(pool).GetImportRunByID
	writeJSON(w, http.StatusOK, map[string]string{"status": "not implemented"})
}

// GetActualsRollup handles GET /api/import/{id}/rollup
func (h *ActualsHandler) GetActualsRollup(w http.ResponseWriter, r *http.Request) {
	id, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}

	rows, err := h.reporting.ActualsRollupByCC(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// GetMoMDelta handles GET /api/import/diff?prev=<id>&curr=<id>
func (h *ActualsHandler) GetMoMDelta(w http.ResponseWriter, r *http.Request) {
	prev, ok := parseUUID(w, r.URL.Query().Get("prev"))
	if !ok {
		return
	}
	curr, ok := parseUUID(w, r.URL.Query().Get("curr"))
	if !ok {
		return
	}

	rows, err := h.reporting.ActualsMoMDelta(r.Context(), prev, curr)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}
