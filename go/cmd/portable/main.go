// portable does the same blob work as blobctl, but through the Go CDK's
// storage-agnostic API. Everything is driven by one URL, so dev and prod
// differ by a string in the environment rather than by a code path:
//
//	azblob://data?protocol=http&domain=127.0.0.1:10000&localemu=true   Azurite
//	azblob://data                                                      real Azure
//	s3://data?endpoint=127.0.0.1:8080&region=us-east-1&...             via s3proxy
//	file:///tmp/blobs                                                  local disk
//	mem://                                                             tests
//
// Credentials come from the environment the chosen driver expects
// (AZURE_STORAGE_ACCOUNT / AZURE_STORAGE_KEY, AWS_ACCESS_KEY_ID, ...).
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	_ "blobexplorer/internal/config" // loads .env

	"gocloud.dev/blob"
	_ "gocloud.dev/blob/azureblob"
	_ "gocloud.dev/blob/fileblob"
	_ "gocloud.dev/blob/memblob"
	_ "gocloud.dev/blob/s3blob"
)

const defaultURL = "azblob://data?protocol=http&domain=127.0.0.1:10000&localemu=true"

const usage = `portable - one blob API over Azurite, Azure, S3 or local disk

  portable ls   [prefix]
  portable cat  <key>
  portable put  <key> < file
  portable rm   <key>

Set BLOB_URL to change backend (default: ` + defaultURL + `)
`

func main() {
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()
	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}

	url := os.Getenv("BLOB_URL")
	if url == "" {
		url = defaultURL
	}

	ctx := context.Background()
	bucket, err := blob.OpenBucket(ctx, url)
	check(err)
	defer bucket.Close()

	switch args[0] {
	case "ls":
		prefix := ""
		if len(args) > 1 {
			prefix = args[1]
		}
		check(list(ctx, bucket, prefix))
	case "cat":
		check(needArg(args, 1, "cat needs a key"))
		r, err := bucket.NewReader(ctx, args[1], nil)
		check(err)
		defer r.Close()
		_, err = io.Copy(os.Stdout, r)
		check(err)
	case "put":
		check(needArg(args, 1, "put needs a key"))
		w, err := bucket.NewWriter(ctx, args[1], nil)
		check(err)
		_, err = io.Copy(w, os.Stdin)
		check(err)
		check(w.Close())
		fmt.Fprintf(os.Stderr, "wrote %s\n", args[1])
	case "rm":
		check(needArg(args, 1, "rm needs a key"))
		check(bucket.Delete(ctx, args[1]))
		fmt.Fprintf(os.Stderr, "deleted %s\n", args[1])
	default:
		flag.Usage()
		os.Exit(2)
	}
}

// list walks one level at a time, so blob prefixes render as directories --
// the same delimiter trick blobctl uses, but portable across every driver.
func list(ctx context.Context, bucket *blob.Bucket, prefix string) error {
	iter := bucket.List(&blob.ListOptions{Prefix: prefix, Delimiter: "/"})
	for {
		obj, err := iter.Next(ctx)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if obj.IsDir {
			fmt.Printf("%10s  %s\n", "-", obj.Key)
			continue
		}
		fmt.Printf("%10d  %s\n", obj.Size, obj.Key)
	}
}

func needArg(args []string, i int, msg string) error {
	if i >= len(args) {
		return fmt.Errorf("%s", msg)
	}
	return nil
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "portable:", err)
		os.Exit(1)
	}
}
