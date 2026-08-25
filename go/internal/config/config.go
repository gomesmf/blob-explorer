// Package config resolves Azurite/Azure settings from .env or the environment.
package config

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// DefaultConnectionString targets Azurite's well-known dev account.
const DefaultConnectionString = "DefaultEndpointsProtocol=http;" +
	"AccountName=devstoreaccount1;" +
	"AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;" +
	"BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;"

func init() { loadDotEnv() }

// loadDotEnv walks up from the working directory looking for .env and fills in
// any variable not already set, so an explicit env var always wins.
func loadDotEnv() {
	dir, err := os.Getwd()
	if err != nil {
		return
	}
	for {
		f, err := os.Open(filepath.Join(dir, ".env"))
		if err == nil {
			defer f.Close()
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				key, value, ok := strings.Cut(line, "=")
				if !ok {
					continue
				}
				key = strings.TrimSpace(key)
				if _, exists := os.LookupEnv(key); !exists {
					os.Setenv(key, strings.TrimSpace(value))
				}
			}
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return
		}
		dir = parent
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ConnectionString is the Azure Storage connection string.
func ConnectionString() string {
	return env("AZURE_STORAGE_CONNECTION_STRING", DefaultConnectionString)
}

// Container is the default blob container.
func Container() string { return env("BLOB_CONTAINER", "data") }

// AccountKey is the shared key, needed by SDKs that do not parse a
// connection string.
func AccountKey() string {
	return env("AZURE_STORAGE_KEY",
		"Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==")
}

// AccountName is the storage account name.
func AccountName() string { return env("AZURE_STORAGE_ACCOUNT", "devstoreaccount1") }
