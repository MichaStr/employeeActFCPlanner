package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	apimw "github.com/yourorg/workforce-planning/internal/api/middleware"
	"github.com/yourorg/workforce-planning/internal/service"
)

// ForecastHandler handles forecast version and entry endpoints.
type ForecastHandler struct {
	forecast  *service.ForecastService
	reporting *service.ReportingService
}

// NewForecastHandler creates a ForecastHandler.
func NewForecastHandler(forecast *service.ForecastService, reporting *service.ReportingService) *ForecastHandler {
	return &ForecastHandler{forecast: forecast, reporting: reporting}
}

// ListVersions handles GET /api/versions
func (h *ForecastHandler) ListVersions(w http.ResponseWriter, r *http.Request) {
	// TODO: call h.forecast.ListVersions and respond with JSON
	writeJSON(w, http.StatusOK, map[string]string{"status": "not implemented"})
}

// CreateVersion handles POST /api/versions
// Body: {"label":"2025-07","period_year":2025,"period_month":7,"fc_horizon_months":18}
func (h *ForecastHandler) CreateVersion(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Label           string `json:"label"`
		PeriodYear      int16  `json:"period_year"`
		PeriodMonth     int16  `json:"period_month"`
		FcHorizonMonths int16  `json:"fc_horizon_months"`
	}
	if !decodeBody(w, r, &req) {
		return
	}

	userID := apimw.UserIDFromContext(r.Context())
	version, err := h.forecast.CreateInitialVersion(r.Context(), userID, req.Label, req.PeriodYear, req.PeriodMonth, req.FcHorizonMonths)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, version)
}

// GetVersion handles GET /api/versions/{id}
func (h *ForecastHandler) GetVersion(w http.ResponseWriter, r *http.Request) {
	// TODO: look up version by ID and respond
	writeJSON(w, http.StatusOK, map[string]string{"status": "not implemented"})
}

// ArchiveVersion handles POST /api/versions/{id}/archive
// Rolls over to a new working version; body contains the new version label and period.
func (h *ForecastHandler) ArchiveVersion(w http.ResponseWriter, r *http.Request) {
	var req struct {
		NewLabel        string `json:"new_label"`
		NewPeriodYear   int16  `json:"new_period_year"`
		NewPeriodMonth  int16  `json:"new_period_month"`
		FcHorizonMonths int16  `json:"fc_horizon_months"`
	}
	if !decodeBody(w, r, &req) {
		return
	}

	userID := apimw.UserIDFromContext(r.Context())
	newVersion, err := h.forecast.ArchiveAndSeed(r.Context(), userID, req.NewLabel, req.NewPeriodYear, req.NewPeriodMonth, req.FcHorizonMonths)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, newVersion)
}

// GetVersionChain handles GET /api/versions/{id}/chain
func (h *ForecastHandler) GetVersionChain(w http.ResponseWriter, r *http.Request) {
	// TODO: call GetVersionChain query
	writeJSON(w, http.StatusOK, map[string]string{"status": "not implemented"})
}

// UpsertEmployeeEntry handles POST /api/versions/{id}/entries
// Applies an SCD Type 2 change for an employee or container.
func (h *ForecastHandler) UpsertEmployeeEntry(w http.ResponseWriter, r *http.Request) {
	versionID, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}

	var req struct {
		EmployeeID  *uuid.UUID `json:"employee_id"`
		ContainerID *uuid.UUID `json:"container_id"`
		service.EmployeeChangeParams
	}
	if !decodeBody(w, r, &req) {
		return
	}

	userID := apimw.UserIDFromContext(r.Context())
	req.EmployeeChangeParams.VersionID = versionID

	entry, err := h.forecast.ApplyEmployeeChange(r.Context(), userID, req.EmployeeChangeParams)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, entry)
}

// DeleteEntry handles DELETE /api/versions/{id}/entries/{entryID}
func (h *ForecastHandler) DeleteEntry(w http.ResponseWriter, r *http.Request) {
	versionID, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}
	entryID, ok := parseUUID(w, chi.URLParam(r, "entryID"))
	if !ok {
		return
	}

	userID := apimw.UserIDFromContext(r.Context())
	if err := h.forecast.SoftDeleteEmployee(r.Context(), userID, versionID, entryID); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GetEntryHistory handles GET /api/versions/{id}/entries/{entryID}/history
func (h *ForecastHandler) GetEntryHistory(w http.ResponseWriter, r *http.Request) {
	// TODO: call GetAuditHistoryForEntry
	writeJSON(w, http.StatusOK, map[string]string{"status": "not implemented"})
}

// GetMonthlyRollup handles GET /api/versions/{id}/rollup?start=2025-01-01&end=2026-06-01
func (h *ForecastHandler) GetMonthlyRollup(w http.ResponseWriter, r *http.Request) {
	versionID, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}

	startMonth, ok := parseDate(w, r.URL.Query().Get("start"))
	if !ok {
		return
	}
	endMonth, ok := parseDate(w, r.URL.Query().Get("end"))
	if !ok {
		return
	}

	rows, err := h.reporting.GetMonthlyRollup(r.Context(), versionID, startMonth, endMonth)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// DiffByCC handles GET /api/diff/cc?version_a=...&version_b=...&month=2025-07-01
func (h *ForecastHandler) DiffByCC(w http.ResponseWriter, r *http.Request) {
	versionA, ok := parseUUID(w, r.URL.Query().Get("version_a"))
	if !ok {
		return
	}
	versionB, ok := parseUUID(w, r.URL.Query().Get("version_b"))
	if !ok {
		return
	}
	month, ok := parseDate(w, r.URL.Query().Get("month"))
	if !ok {
		return
	}

	rows, err := h.reporting.DiffVersionsByCC(r.Context(), versionA, versionB, month)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// DiffByEmployee handles GET /api/diff/employee?version_a=...&version_b=...&month=2025-07-01
func (h *ForecastHandler) DiffByEmployee(w http.ResponseWriter, r *http.Request) {
	versionA, ok := parseUUID(w, r.URL.Query().Get("version_a"))
	if !ok {
		return
	}
	versionB, ok := parseUUID(w, r.URL.Query().Get("version_b"))
	if !ok {
		return
	}
	month, ok := parseDate(w, r.URL.Query().Get("month"))
	if !ok {
		return
	}

	rows, err := h.reporting.DiffVersionsByEmployee(r.Context(), versionA, versionB, month)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return false
	}
	return true
}

func parseUUID(w http.ResponseWriter, raw string) (uuid.UUID, bool) {
	id, err := uuid.Parse(raw)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return uuid.UUID{}, false
	}
	return id, true
}

func parseDate(w http.ResponseWriter, raw string) (time.Time, bool) {
	t, err := time.Parse("2006-01-02", raw)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return time.Time{}, false
	}
	return t, true
}
