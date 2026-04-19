package cli

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/spf13/cobra"
	"github.com/yourorg/workforce-planning/internal/config"
	"github.com/yourorg/workforce-planning/internal/db"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Manage forecast versions",
}

var versionListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all forecast versions, newest first",
	RunE:  runVersionList,
}

var versionChainCmd = &cobra.Command{
	Use:   "chain <version-id>",
	Short: "Walk the version chain from a given version back to the root",
	Args:  cobra.ExactArgs(1),
	RunE:  runVersionChain,
}

func init() {
	versionCmd.AddCommand(versionListCmd)
	versionCmd.AddCommand(versionChainCmd)
	rootCmd.AddCommand(versionCmd)
}

func runVersionList(cmd *cobra.Command, _ []string) error {
	q, pool, err := openQueries(cmd)
	if err != nil {
		return err
	}
	defer pool.Close()

	versions, err := q.ListForecastVersions(context.Background())
	if err != nil {
		return fmt.Errorf("list versions: %w", err)
	}

	fmt.Printf("%-36s  %-20s  %-8s  %s\n", "ID", "Label", "Status", "Period")
	for _, v := range versions {
		fmt.Printf("%-36s  %-20s  %-8s  %4d-%02d\n",
			v.ID, v.Label, v.Status, v.PeriodYear, v.PeriodMonth)
	}
	return nil
}

func runVersionChain(cmd *cobra.Command, args []string) error {
	startID, err := uuid.Parse(args[0])
	if err != nil {
		return fmt.Errorf("invalid version UUID %q: %w", args[0], err)
	}

	q, pool, err := openQueries(cmd)
	if err != nil {
		return err
	}
	defer pool.Close()

	chain, err := q.GetVersionChain(context.Background(), startID)
	if err != nil {
		return fmt.Errorf("get version chain: %w", err)
	}

	for _, v := range chain {
		fmt.Printf("#%-3d  %-36s  %-20s  %-8s  %4d-%02d\n",
			v.Position, v.ID, v.Label, v.Status, v.PeriodYear, v.PeriodMonth)
	}
	return nil
}

// openQueries is a shared helper to open a pgxpool and return a *db.Queries.
func openQueries(cmd *cobra.Command) (*db.Queries, *pgxpool.Pool, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil, err
	}
	if dbFlag, _ := cmd.Flags().GetString("db"); dbFlag != "" {
		cfg.DatabaseURL = dbFlag
	}

	pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		return nil, nil, fmt.Errorf("connect to database: %w", err)
	}
	return db.New(pool), pool, nil
}
