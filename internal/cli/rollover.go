package cli

import (
	"context"
	"fmt"
	"os"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/spf13/cobra"
	"github.com/yourorg/workforce-planning/internal/config"
	"github.com/yourorg/workforce-planning/internal/service"
)

var rolloverCmd = &cobra.Command{
	Use:   "rollover",
	Short: "Archive the working forecast and seed a new working version",
	Long: `rollover performs the month-end close in a single transaction:
  1. Archives the current working forecast version.
  2. Creates a new working version pointing back to the archive.
  3. Seeds all active entries from the archive into the new version.

Example:
  wfp rollover --label "2025-08" --year 2025 --month 8 --horizon 18 --user <uuid>`,
	RunE: runRollover,
}

func init() {
	rolloverCmd.Flags().String("label", "", "Label for the new working version (required)")
	rolloverCmd.Flags().Int16("year", 0, "Period year for the new version (required)")
	rolloverCmd.Flags().Int16("month", 0, "Period month for the new version (required)")
	rolloverCmd.Flags().Int16("horizon", 18, "Forecast horizon in months")
	rolloverCmd.Flags().String("user", "", "User UUID performing the rollover (required)")
	rolloverCmd.MarkFlagRequired("label") //nolint:errcheck
	rolloverCmd.MarkFlagRequired("year")  //nolint:errcheck
	rolloverCmd.MarkFlagRequired("month") //nolint:errcheck
	rolloverCmd.MarkFlagRequired("user")  //nolint:errcheck

	rootCmd.AddCommand(rolloverCmd)
}

func runRollover(cmd *cobra.Command, _ []string) error {
	label, _ := cmd.Flags().GetString("label")
	year, _ := cmd.Flags().GetInt16("year")
	month, _ := cmd.Flags().GetInt16("month")
	horizon, _ := cmd.Flags().GetInt16("horizon")
	userRaw, _ := cmd.Flags().GetString("user")

	userID, err := uuid.Parse(userRaw)
	if err != nil {
		return fmt.Errorf("invalid --user UUID: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if dbFlag, _ := cmd.Flags().GetString("db"); dbFlag != "" {
		cfg.DatabaseURL = dbFlag
	}

	pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer pool.Close()

	svc := service.NewForecastService(pool)
	newVersion, err := svc.ArchiveAndSeed(context.Background(), userID, label, year, month, horizon)
	if err != nil {
		return fmt.Errorf("rollover failed: %w", err)
	}

	fmt.Fprintf(os.Stdout, "Rollover complete: new version id=%s label=%s\n",
		newVersion.ID, newVersion.Label)
	return nil
}
