package main

// `jg-teardown preserve --worktree W --dest D` keeps everything a copy holds beyond its HEAD before the
// copy is given back: tracked changes (staged and unstaged, deletions included), untracked and ignored
// files, and nested repositories walked whole. It only reads the copy (git with --no-optional-locks).
// D (0700) holds manifest.json - the head, the staged patch's SHA-256, and per path its class, kind
// (file, symlink, dir, deleted), permission bits and SHA-256 - and files/<sha256> for every byte stream,
// the staged patch included. D is built in a sibling .<D>.tmp-*: every blob is read back against its
// hash, the copy is listed again and must still match, and only then is the sibling renamed to D, so D
// is whole or absent and a crash leaves only the sibling. A rerun over an existing D passes only when D
// proves itself and matches the copy now (a crash after the rename converges); any other D is refused,
// never overwritten. An empty directory git does not list has nothing to keep; the caller stops the
// lane's writers first. Exit 0 prints retained=, entries=, head=; 1 a reason=<word> below; 2 is invalid.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

const (
	keepUnreadable  = "unreadable-copy"  // git or the file system cannot read the copy
	keepUnsupported = "unsupported-file" // a socket, device or pipe has no bytes to keep
	keepChanged     = "concurrent-write" // the copy changed while it was being kept
	keepDestination = "destination"      // the retention cannot be written or reads back wrong
	keepExists      = "exists-differs"   // D exists and does not prove itself against the copy
)

type kept struct {
	Path   string      `json:"path"`
	Class  string      `json:"class"`
	Kind   string      `json:"kind"`
	Mode   fs.FileMode `json:"mode,omitempty"`
	SHA256 string      `json:"sha256,omitempty"`
}

type keptManifest struct {
	Head    string `json:"head"`
	Staged  string `json:"staged_sha256"`
	Entries []kept `json:"entries"`
}

type keepErr struct{ reason, msg string }

func (e *keepErr) Error() string { return e.msg }

func keepFail(reason, f string, a ...any) error { return &keepErr{reason, fmt.Sprintf(f, a...)} }

func lgit(wt string, a ...string) (string, error) {
	return run("", "git", append([]string{"--no-optional-locks", "-C", wt}, a...)...)
}

// destWriter remembers a failed write, so a full or broken destination is never read as a bad source.
type destWriter struct {
	w   io.Writer
	err error
}

func (d *destWriter) Write(p []byte) (int, error) {
	n, err := d.w.Write(p)
	d.err = errors.Join(d.err, err)
	return n, err
}

// keepBytes hashes src and, when blobs is set, stores its bytes there, synced, as <sha256>.
func keepBytes(src io.Reader, blobs, what string) (string, error) {
	h, dw := sha256.New(), &destWriter{w: io.Discard}
	var tmp *os.File
	if blobs != "" {
		var err error
		if tmp, err = os.CreateTemp(blobs, ".in-"); err != nil {
			return "", keepFail(keepDestination, "the retention cannot be written: %v", err)
		}
		defer tmp.Close()
		dw.w = tmp
	}
	_, err := io.Copy(io.MultiWriter(h, dw), src)
	sum := hex.EncodeToString(h.Sum(nil))
	if err != nil && dw.err == nil {
		return "", keepFail(keepUnreadable, "%s cannot be read whole: %v", what, err)
	}
	if err == nil && tmp != nil {
		err = errors.Join(tmp.Sync(), os.Rename(tmp.Name(), filepath.Join(blobs, sum)))
	}
	if err != nil {
		return "", keepFail(keepDestination, "the retention cannot be written: %v", err)
	}
	return sum, nil
}

// list reads the copy as it is now; with blobs set, every byte stream is kept there as it is hashed.
func list(wt, blobs string) (*keptManifest, error) {
	m := &keptManifest{}
	var err error
	if m.Head, err = lgit(wt, "rev-parse", "--verify", "HEAD"); err != nil {
		return nil, keepFail(keepUnreadable, "the copy at %s has no readable HEAD", wt)
	}
	// Read raw: a patch cut at its last newline no longer applies.
	patch, err := exec.Command("git", "--no-optional-locks", "-C", wt, "diff", "--cached", "--binary", "--no-renames", "--no-ext-diff", "HEAD").Output()
	if err != nil {
		return nil, keepFail(keepUnreadable, "the staged changes of %s cannot be read", wt)
	}
	if m.Staged, err = keepBytes(bytes.NewReader(patch), blobs, "the staged patch"); err != nil {
		return nil, err
	}
	for _, c := range [][]string{
		{"tracked", "diff", "--name-only", "-z", "--no-renames", "HEAD"},
		{"untracked", "ls-files", "-z", "--others", "--exclude-standard"},
		{"ignored", "ls-files", "-z", "--others", "--ignored", "--exclude-standard"},
	} {
		out, err := lgit(wt, c[1:]...)
		if err != nil {
			return nil, keepFail(keepUnreadable, "the %s paths of %s cannot be listed", c[0], wt)
		}
		for _, p := range strings.Split(out, "\x00") {
			if p = strings.TrimSuffix(p, "/"); p != "" {
				if err := walkKept(wt, p, c[0], blobs, m); err != nil {
					return nil, err
				}
			}
		}
	}
	sort.Slice(m.Entries, func(i, j int) bool { return m.Entries[i].Path < m.Entries[j].Path })
	return m, nil
}

// walkKept adds rel - a file, a link, a tracked path that is gone, or a directory walked whole - to m.
func walkKept(wt, rel, class, blobs string, m *keptManifest) error {
	if _, err := os.Lstat(filepath.Join(wt, rel)); errors.Is(err, fs.ErrNotExist) && class == "tracked" {
		m.Entries = append(m.Entries, kept{Path: rel, Class: class, Kind: "deleted"})
		return nil
	}
	return filepath.WalkDir(filepath.Join(wt, rel), func(p string, d fs.DirEntry, err error) error {
		var info fs.FileInfo
		if err == nil {
			info, err = d.Info()
		}
		if errors.Is(err, fs.ErrNotExist) {
			return keepFail(keepChanged, "%s vanished while it was being kept", p)
		} else if err != nil {
			return keepFail(keepUnreadable, "%s cannot be read: %v", p, err)
		}
		r, _ := filepath.Rel(wt, p)
		e := kept{Path: filepath.ToSlash(r), Class: class, Mode: info.Mode().Perm()}
		var src io.Reader
		switch {
		case d.IsDir():
			e.Kind = "dir" // kept, so a nested repository's empty refs/ and objects/ come back
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(p)
			if err != nil {
				return keepFail(keepUnreadable, "the link %s cannot be read: %v", p, err)
			}
			e.Kind, e.Mode, src = "symlink", 0, strings.NewReader(target)
		case info.Mode().IsRegular():
			f, err := os.Open(p)
			if err != nil {
				return keepFail(keepChanged, "%s could not be opened while it was being kept: %v", p, err)
			}
			defer f.Close()
			e.Kind, src = "file", f
		default:
			return keepFail(keepUnsupported, "%s is a %s, which has no bytes to keep", p, info.Mode().Type())
		}
		if src != nil {
			if e.SHA256, err = keepBytes(src, blobs, p); err != nil {
				return err
			}
		}
		m.Entries = append(m.Entries, e)
		return nil
	})
}

// proveRetention reads D back: the manifest parses and every kept byte stream matches its hash.
func proveRetention(dest string) (*keptManifest, error) {
	m := &keptManifest{}
	b, err := os.ReadFile(filepath.Join(dest, "manifest.json"))
	if err == nil {
		err = json.Unmarshal(b, m)
	}
	sums := []string{m.Staged}
	for _, e := range m.Entries {
		if e.SHA256 != "" {
			sums = append(sums, e.SHA256)
		}
	}
	for i := 0; err == nil && i < len(sums); i++ {
		var f *os.File
		if f, err = os.Open(filepath.Join(dest, "files", sums[i])); err == nil {
			var got string
			if got, err = keepBytes(f, "", sums[i]); err == nil && got != sums[i] {
				err = fmt.Errorf("the blob %s does not match its hash", sums[i])
			}
			f.Close()
		}
	}
	if err != nil {
		return nil, keepFail(keepDestination, "the retention %s does not prove itself: %v", dest, err)
	}
	return m, nil
}

func runPreserve(args []string) int {
	var wt, dest string
	fs := flag.NewFlagSet("preserve", flag.ContinueOnError)
	fs.StringVar(&wt, "worktree", "", "the copy's top level")
	fs.StringVar(&dest, "dest", "", "the retention directory, absolute and outside the copy")
	perr := fs.Parse(args)
	top, err := lgit(wt, "rev-parse", "--show-toplevel")
	real, _ := filepath.EvalSymlinks(wt)
	if dest = filepath.Clean(dest); perr != nil || wt == "" || err != nil || top != real || !filepath.IsAbs(dest) || strings.HasPrefix(dest+"/", top+"/") {
		fmt.Fprintln(os.Stderr, "preserve: --worktree must be a copy's top level and --dest an absolute path outside it")
		return safetyInvalid
	}
	m, err := preserveInto(real, dest)
	if k := (&keepErr{reason: keepUnreadable}); err != nil {
		errors.As(err, &k)
		return refuse(k.reason, "REFUSED: "+err.Error())
	}
	fmt.Printf("retained=%s\nentries=%d\nhead=%s\n", dest, len(m.Entries), m.Head)
	return safetyOK
}

func preserveInto(wt, dest string) (*keptManifest, error) {
	if _, err := os.Lstat(dest); err == nil {
		return keepExisting(wt, dest)
	}
	tmp, err := "", os.MkdirAll(filepath.Dir(dest), 0o700)
	if err == nil {
		tmp, err = os.MkdirTemp(filepath.Dir(dest), "."+filepath.Base(dest)+".tmp-")
	}
	if err == nil {
		defer os.RemoveAll(tmp)
		err = os.Mkdir(filepath.Join(tmp, "files"), 0o700)
	}
	if err != nil {
		return nil, keepFail(keepDestination, "the retention cannot be made: %v", err)
	}
	m, err := list(wt, filepath.Join(tmp, "files"))
	if err != nil {
		return nil, err
	}
	b, _ := json.MarshalIndent(m, "", " ")
	sum, err := keepBytes(bytes.NewReader(b), tmp, "the manifest")
	if err == nil {
		err = os.Rename(filepath.Join(tmp, sum), filepath.Join(tmp, "manifest.json"))
	}
	if err == nil {
		_, err = proveRetention(tmp)
	}
	if err != nil {
		return nil, errors.Join(err, keepFail(keepDestination, "the retention cannot be written"))
	}
	if again, err := list(wt, ""); err != nil || !reflect.DeepEqual(m, again) {
		return nil, errors.Join(err, keepFail(keepChanged, "%s changed while it was being kept; stop its writer and preserve again", wt))
	}
	if err := os.Rename(tmp, dest); err != nil {
		if _, serr := os.Lstat(dest); serr == nil {
			return keepExisting(wt, dest) // another run published first
		}
		return nil, keepFail(keepDestination, "the retention could not be published: %v", err)
	}
	return m, nil
}

func keepExisting(wt, dest string) (*keptManifest, error) {
	m, err := proveRetention(dest)
	if err != nil {
		return nil, keepFail(keepExists, "%s exists and does not prove itself (%v); it is not overwritten", dest, err)
	}
	if now, err := list(wt, ""); err != nil || !reflect.DeepEqual(m, now) {
		return nil, errors.Join(err, keepFail(keepExists, "%s keeps another state of %s; it is not overwritten", dest, wt))
	}
	return m, nil
}
