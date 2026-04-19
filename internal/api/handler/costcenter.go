package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/yourorg/workforce-planning/internal/db"
)

// CostcenterHandler handles cost center hierarchy endpoints.
type CostcenterHandler struct {
	pool *pgxpool.Pool
}

// NewCostcenterHandler creates a CostcenterHandler.
func NewCostcenterHandler(pool *pgxpool.Pool) *CostcenterHandler {
	return &CostcenterHandler{pool: pool}
}

// ListActive handles GET /api/costcenters
// Returns a flat list of active cost centers ordered by level then code.
func (h *CostcenterHandler) ListActive(w http.ResponseWriter, r *http.Request) {
	rows, err := db.New(h.pool).ListActiveCostcenters(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// GetTree handles GET /api/costcenters/tree
// Returns the full active hierarchy annotated with ancestry path arrays.
func (h *CostcenterHandler) GetTree(w http.ResponseWriter, r *http.Request) {
	rows, err := db.New(h.pool).GetCostcenterTree(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// GetByID handles GET /api/costcenters/{id}
func (h *CostcenterHandler) GetByID(w http.ResponseWriter, r *http.Request) {
	id, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}

	row, err := db.New(h.pool).GetCostcenterByID(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, row)
}

// GetDescendants handles GET /api/costcenters/{id}/descendants
// Returns all active cost centers under the given node (inclusive).
func (h *CostcenterHandler) GetDescendants(w http.ResponseWriter, r *http.Request) {
	id, ok := parseUUID(w, chi.URLParam(r, "id"))
	if !ok {
		return
	}

	rows, err := db.New(h.pool).GetCostcenterDescendants(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}
