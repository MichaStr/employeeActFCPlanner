// Package cli contains the Cobra command tree for the wfp command-line tool.
// Each subcommand is defined in its own file and registered in init().
// cmd/cli/main.go calls Execute() to start the program.
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "wfp",
	Short: "Workforce planning CLI",
	Long: `wfp — command-line tool for the workforce planning database.

Subcommands:
  import    Load a monthly SAP export into employee_actuals
  rollover  Archive the working forecast and seed a new working version
  version   Manage forecast versions (list, inspect)`,
}

// Execute runs the CLI. Called from cmd/cli/main.go.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func init() {
	// Persistent flags available to all subcommands.
	rootCmd.PersistentFlags().String("db", "", "Database URL (overrides DATABASE_URL env var)")
}
