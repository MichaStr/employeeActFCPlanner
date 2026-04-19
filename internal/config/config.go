package config

import (
	"fmt"
	"os"

	"github.com/joho/godotenv"
)

// Config holds all runtime settings loaded from environment variables.
//
// Variables are resolved in this order (highest priority first):
//  1. Existing OS environment variables
//  2. .env file in the current working directory (if present)
//
// Required: DATABASE_URL.
// Optional: PORT (default 8080), LOG_LEVEL (default "info"), JWT_SECRET.
type Config struct {
	DatabaseURL string
	Port        string
	LogLevel    string
	JWTSecret   string
}

// Load reads configuration from environment variables.
// It first attempts to load a .env file from the current directory;
// existing OS environment variables always take precedence over .env values.
// Returns an error if DATABASE_URL is not set after loading.
func Load() (*Config, error) {
	// Load .env if present. godotenv does NOT overwrite variables that are
	// already set in the OS environment, so deployment env vars win.
	// A missing .env file is silently ignored — it is optional in production.
	if err := godotenv.Load(); err != nil && !os.IsNotExist(err) {
		// File exists but could not be parsed — surface the error.
		return nil, fmt.Errorf("parse .env file: %w", err)
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required (set env var or add it to .env)")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	logLevel := os.Getenv("LOG_LEVEL")
	if logLevel == "" {
		logLevel = "info"
	}

	return &Config{
		DatabaseURL: dbURL,
		Port:        port,
		LogLevel:    logLevel,
		JWTSecret:   os.Getenv("JWT_SECRET"),
	}, nil
}
