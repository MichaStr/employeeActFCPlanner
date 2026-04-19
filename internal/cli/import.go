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

var importCmd = &cobra.Command{
	Use:   "import",
	Short: "Load a monthly SAP export into employee_actuals",
	Long: `import reads a parsed SAP export and bulk-inserts it as employee_actuals.

The file argument is informational only (stored on the import_run record).
Pass the actual row data via stdin as newline-delimited JSON, or implement
a file parser and pass rows directly in the RunE body below.

Example:
  wfp import --year 2025 --month 7 --file export_2025_07.xlsx --user <uuid>`,
	RunE: runImport,
}

func init() {
	importCmd.Flags().Int16("year", 0, "Fiscal year (required)")
	importCmd.Flags().Int16("month", 0, "Fiscal month 1-12 (required)")
	importCmd.Flags().String("file", "", "Source file name (informational)")
	importCmd.Flags().String("user", "", "Importing user UUID (required)")
	importCmd.MarkFlagRequired("year")   //nolint:errcheck
	importCmd.MarkFlagRequired("month")  //nolint:errcheck
	importCmd.MarkFlagRequired("user")   //nolint:errcheck

	rootCmd.AddCommand(importCmd)
}

func runImport(cmd *cobra.Command, _ []string) error {
	year, _ := cmd.Flags().GetInt16("year")
	month, _ := cmd.Flags().GetInt16("month")
	fileName, _ := cmd.Flags().GetString("file")
	userRaw, _ := cmd.Flags().GetString("user")

	userID, err := uuid.Parse(userRaw)
	if err != nil {
		return fmt.Errorf("invalid --user UUID: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	// Override with --db flag if provided.
	if dbFlag, _ := cmd.Flags().GetString("db"); dbFlag != "" {
		cfg.DatabaseURL = dbFlag
	}

	pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer pool.Close()

	svc := service.NewActualsService(pool)

	// TODO: parse the actual file here and populate rows.
	// For now this demonstrates the wiring — replace with real CSV/Excel parsing.
	var rows []service.ImportRow
	var sourceFile *string
	if fileName != "" {
		sourceFile = &fileName
	}

	run, err := svc.RunImport(context.Background(), userID, year, month, sourceFile, rows)
	if err != nil {
		return fmt.Errorf("import failed: %w", err)
	}

	fmt.Fprintf(os.Stdout, "Import complete: run_id=%s rows=%d\n",
		run.ID, func() int32 {
			if run.RowCount == nil {
				return 0
			}
			return *run.RowCount
		}())
	return nil
}
