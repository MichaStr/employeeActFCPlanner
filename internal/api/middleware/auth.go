package middleware

import (
	"context"
	"net/http"

	"github.com/google/uuid"
)

type contextKey string

const userIDKey contextKey = "userID"

// Authenticate validates the request identity and injects the user UUID into the context.
// Replace this stub with your chosen auth mechanism (JWT, session cookie, API key, etc.).
//
// Current behaviour: reads X-User-ID header as a UUID.
// In production, verify a signed JWT and extract the sub claim instead.
func Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get("X-User-ID")
		if raw == "" {
			http.Error(w, "missing X-User-ID header", http.StatusUnauthorized)
			return
		}

		userID, err := uuid.Parse(raw)
		if err != nil {
			http.Error(w, "invalid X-User-ID", http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), userIDKey, userID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// UserIDFromContext retrieves the authenticated user's UUID from the request context.
// Panics if called outside of the Authenticate middleware chain.
func UserIDFromContext(ctx context.Context) uuid.UUID {
	id, _ := ctx.Value(userIDKey).(uuid.UUID)
	return id
}
