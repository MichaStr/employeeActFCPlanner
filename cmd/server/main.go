package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/yourorg/workforce-planning/internal/api"
	"github.com/yourorg/workforce-planning/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("config error", "err", err)
		os.Exit(1)
	}

	pool, err := newPool(context.Background(), cfg.DatabaseURL)
	if err != nil {
		slog.Error("database connection failed", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	router := api.NewRouter(pool)
	addr := fmt.Sprintf(":%s", cfg.Port)
	slog.Info("server starting", "addr", addr)

	if err := http.ListenAndServe(addr, router); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

// newPool creates a pgxpool with codec registration required for custom types.
//
// UUID (github.com/google/uuid) is natively supported by pgx v5.
//
// For shopspring/decimal, register the pgxdecimal codec.
// Add the dependency:  go get github.com/jackc/pgx-shopspring-decimal
// Then uncomment the AfterConnect block below.
func newPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	poolCfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database URL: %w", err)
	}

	// Register custom type codecs on every new connection.
	poolCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		// pgx v5 handles uuid.UUID natively — no registration needed.

		// Uncomment once you add github.com/jackc/pgx-shopspring-decimal:
		//   pgxdecimal.Register(conn.TypeMap())

		_ = ctx
		return nil
	}

	return pgxpool.NewWithConfig(ctx, poolCfg)
}
