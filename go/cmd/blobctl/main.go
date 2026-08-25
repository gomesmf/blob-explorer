// blobctl browses and moves blobs with the official Azure SDK.
//
// The interesting part is `tree`: blob storage has a flat namespace, and the
// only thing that makes it look like a filesystem is listing with a "/"
// delimiter so common prefixes come back as BlobPrefixes. Every decent blob
// browser is doing exactly this under the hood.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"

	"blobexplorer/internal/config"

	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/container"
)

const usage = `blobctl - browse Azure Blob Storage / Azurite

  blobctl ls   [prefix]           one level, directories first
  blobctl tree [prefix]           recursive tree with sizes
  blobctl stat <blob>             size, content type, last modified
  blobctl get  <blob> [dest]      download (dest defaults to basename)
  blobctl put  <file> [blob]      upload
  blobctl rm   <blob>             delete
  blobctl containers              list containers

Paths are relative to $BLOB_CONTAINER (default "data"), or write them as
container/prefix/name to address another container.
`

func main() {
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()

	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}

	client, err := azblob.NewClientFromConnectionString(config.ConnectionString(), nil)
	check(err)

	ctx := context.Background()
	cmd, rest := args[0], args[1:]

	switch cmd {
	case "containers":
		check(listContainers(ctx, client))
	case "ls":
		c, p := split(arg(rest, 0, ""))
		check(list(ctx, client, c, p))
	case "tree":
		c, p := split(arg(rest, 0, ""))
		check(tree(ctx, client, c, p, ""))
	case "stat":
		c, p := split(mustArg(rest, 0, "stat needs a blob name"))
		check(stat(ctx, client, c, p))
	case "get":
		c, p := split(mustArg(rest, 0, "get needs a blob name"))
		check(get(ctx, client, c, p, arg(rest, 1, path.Base(p))))
	case "put":
		src := mustArg(rest, 0, "put needs a local file")
		c, p := split(arg(rest, 1, path.Base(src)))
		check(put(ctx, client, c, p, src))
	case "rm":
		c, p := split(mustArg(rest, 0, "rm needs a blob name"))
		_, err := client.DeleteBlob(ctx, c, p, nil)
		check(err)
		fmt.Printf("deleted %s/%s\n", c, p)
	default:
		flag.Usage()
		os.Exit(2)
	}
}

// split turns "container/prefix/x" into ("container", "prefix/x"). A bare path
// is interpreted inside the default container, which is what you want ~always
// during development.
func split(p string) (string, string) {
	p = strings.TrimPrefix(p, "/")
	def := config.Container()
	if p == "" {
		return def, ""
	}
	head, tail, ok := strings.Cut(p, "/")
	if !ok {
		if head == def {
			return def, ""
		}
		return def, head
	}
	if head == def {
		return def, tail
	}
	return def, p
}

func listContainers(ctx context.Context, client *azblob.Client) error {
	pager := client.NewListContainersPager(nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return err
		}
		for _, c := range page.ContainerItems {
			fmt.Println(*c.Name)
		}
	}
	return nil
}

type entry struct {
	name  string
	dir   bool
	size  int64
	mtime string
}

// level lists exactly one directory level below prefix.
func level(ctx context.Context, client *azblob.Client, cont, prefix string) ([]entry, error) {
	cc := client.ServiceClient().NewContainerClient(cont)
	opts := &container.ListBlobsHierarchyOptions{}
	if prefix != "" {
		p := strings.TrimSuffix(prefix, "/") + "/"
		opts.Prefix = &p
	}
	pager := cc.NewListBlobsHierarchyPager("/", opts)

	var out []entry
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		seg := page.Segment
		for _, p := range seg.BlobPrefixes {
			out = append(out, entry{name: *p.Name, dir: true})
		}
		for _, b := range seg.BlobItems {
			e := entry{name: *b.Name}
			if b.Properties != nil {
				if b.Properties.ContentLength != nil {
					e.size = *b.Properties.ContentLength
				}
				if b.Properties.LastModified != nil {
					e.mtime = b.Properties.LastModified.Format("2006-01-02 15:04")
				}
			}
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].dir != out[j].dir {
			return out[i].dir
		}
		return out[i].name < out[j].name
	})
	return out, nil
}

func list(ctx context.Context, client *azblob.Client, cont, prefix string) error {
	entries, err := level(ctx, client, cont, prefix)
	if err != nil {
		return err
	}
	for _, e := range entries {
		base := path.Base(strings.TrimSuffix(e.name, "/"))
		if e.dir {
			fmt.Printf("%-18s %10s  %s/\n", "", "-", base)
		} else {
			fmt.Printf("%-18s %10s  %s\n", e.mtime, human(e.size), base)
		}
	}
	return nil
}

func tree(ctx context.Context, client *azblob.Client, cont, prefix, indent string) error {
	entries, err := level(ctx, client, cont, prefix)
	if err != nil {
		return err
	}
	if indent == "" {
		fmt.Printf("az://%s/%s\n", cont, prefix)
	}
	for i, e := range entries {
		branch, next := "├── ", indent+"│   "
		if i == len(entries)-1 {
			branch, next = "└── ", indent+"    "
		}
		base := path.Base(strings.TrimSuffix(e.name, "/"))
		if e.dir {
			fmt.Printf("%s%s%s/\n", indent, branch, base)
			if err := tree(ctx, client, cont, strings.TrimSuffix(e.name, "/"), next); err != nil {
				return err
			}
			continue
		}
		fmt.Printf("%s%s%s  %s\n", indent, branch, base, human(e.size))
	}
	return nil
}

func stat(ctx context.Context, client *azblob.Client, cont, blob string) error {
	props, err := client.ServiceClient().NewContainerClient(cont).
		NewBlobClient(blob).GetProperties(ctx, nil)
	if err != nil {
		return err
	}
	fmt.Printf("blob          az://%s/%s\n", cont, blob)
	if props.ContentLength != nil {
		fmt.Printf("size          %s (%d bytes)\n", human(*props.ContentLength), *props.ContentLength)
	}
	if props.ContentType != nil {
		fmt.Printf("content-type  %s\n", *props.ContentType)
	}
	if props.LastModified != nil {
		fmt.Printf("modified      %s\n", props.LastModified.Format("2006-01-02 15:04:05"))
	}
	if props.ETag != nil {
		fmt.Printf("etag          %s\n", *props.ETag)
	}
	return nil
}

func get(ctx context.Context, client *azblob.Client, cont, blob, dest string) error {
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	n, err := client.DownloadFile(ctx, cont, blob, f, nil)
	if err != nil {
		return err
	}
	fmt.Printf("%s -> %s (%s)\n", blob, dest, human(n))
	return nil
}

func put(ctx context.Context, client *azblob.Client, cont, blob, src string) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := client.UploadFile(ctx, cont, blob, f, nil); err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		return err
	}
	fmt.Printf("%s -> az://%s/%s (%s)\n", src, cont, blob, human(info.Size()))
	return nil
}

func human(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGT"[exp])
}

func arg(args []string, i int, fallback string) string {
	if i < len(args) {
		return args[i]
	}
	return fallback
}

func mustArg(args []string, i int, msg string) string {
	if i >= len(args) {
		fmt.Fprintln(os.Stderr, "blobctl:", msg)
		os.Exit(2)
	}
	return args[i]
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "blobctl:", err)
		os.Exit(1)
	}
}

