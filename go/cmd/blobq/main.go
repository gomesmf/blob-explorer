// blobq runs DuckDB in-process and queries Parquet sitting in blob storage --
// the same engine and the same az:// URLs the DuckDB UI uses, so a query you
// prototyped in the UI drops straight into Go.
//
// Needs CGO_ENABLED=1. The azure extension is not statically linked into
// go-duckdb, so the first run downloads it from the DuckDB extension
// repository; after that it is cached in ~/.duckdb/extensions.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"blobexplorer/internal/config"

	_ "github.com/marcboeker/go-duckdb/v2"
)

func main() {
	format := flag.String("format", "table", "table|csv")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "blobq [-format table|csv] \"SELECT ...\"\n\n"+
			"Views `events` (az://) and `events_s3` (s3://) are pre-created.\n")
	}
	flag.Parse()

	query := strings.Join(flag.Args(), " ")
	if query == "" {
		query = "SELECT region, count(*) AS n, round(sum(amount), 2) AS amount " +
			"FROM events GROUP BY region ORDER BY amount DESC"
	}

	db, err := sql.Open("duckdb", "")
	check(err)
	defer db.Close()

	ctx := context.Background()
	check(bootstrap(ctx, db))

	rows, err := db.QueryContext(ctx, query)
	check(err)
	defer rows.Close()
	check(render(rows, *format))
}

// bootstrap mirrors duckdb/init.sql. Parameterising the secret keeps the
// connection string out of the SQL text.
func bootstrap(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `INSTALL azure; LOAD azure;`); err != nil {
		return fmt.Errorf("load azure extension: %w", err)
	}
	if _, err := db.ExecContext(ctx,
		`CREATE OR REPLACE SECRET azurite (TYPE azure, CONNECTION_STRING ?)`,
		config.ConnectionString()); err != nil {
		return fmt.Errorf("create secret: %w", err)
	}
	view := fmt.Sprintf(
		`CREATE OR REPLACE VIEW events AS
		 SELECT * FROM read_parquet('az://%s/events/**/*.parquet', hive_partitioning := true)`,
		config.Container())
	if _, err := db.ExecContext(ctx, view); err != nil {
		return fmt.Errorf("create view: %w", err)
	}
	return nil
}

func render(rows *sql.Rows, format string) error {
	cols, err := rows.Columns()
	if err != nil {
		return err
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	sep := "\t"
	if format == "csv" {
		sep = ","
	}
	fmt.Fprintln(w, strings.Join(cols, sep))

	values := make([]any, len(cols))
	scan := make([]any, len(cols))
	for i := range values {
		scan[i] = &values[i]
	}

	for rows.Next() {
		if err := rows.Scan(scan...); err != nil {
			return err
		}
		cells := make([]string, len(cols))
		for i, v := range values {
			switch t := v.(type) {
			case nil:
				cells[i] = ""
			case []byte:
				cells[i] = string(t)
			default:
				cells[i] = fmt.Sprint(t)
			}
		}
		fmt.Fprintln(w, strings.Join(cells, sep))
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if format != "csv" {
		return w.Flush()
	}
	return w.Flush()
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "blobq:", err)
		os.Exit(1)
	}
}
