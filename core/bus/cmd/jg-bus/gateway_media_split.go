package main

// Tall pictures: one taller than 3:1 is cut into slices a phone can read, in order, before it is sent.

import (
	"fmt"
	"image"
	_ "image/jpeg" // registered so a tall JPEG can be read
	"image/png"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	tallRatio  = 3        // a slice is at most this many times as high as it is wide
	maxSplitPx = 64 << 20 // a picture with more pixels than this is sent whole, not held in memory to cut
)

// sliceCuts returns the rows where the slices of a w by h picture start, then h: slice i spans rows
// cuts[i] to cuts[i+1]. It is nil when the picture is no taller than 3:1. Each slice is 3 x w high; a
// last slice under a third of w is joined to the one before it, so no sliver is sent alone.
func sliceCuts(w, h int) []int {
	if w <= 0 || h <= tallRatio*w {
		return nil
	}
	var cuts []int
	for y := 0; y < h; y += tallRatio * w {
		cuts = append(cuts, y)
	}
	cuts = append(cuts, h)
	if n := len(cuts); h-cuts[n-2] < w/tallRatio {
		cuts = append(cuts[:n-2], h)
	}
	return cuts
}

// sliceDir is where the slices of one reply are written, until that reply is sent.
func (a *app) sliceDir(cursor string) string {
	return filepath.Join(a.state, "captain-chat", "slices", strings.NewReplacer("/", "_", string(filepath.Separator), "_").Replace(cursor))
}

// splitTall returns the slices of a tall picture, in order, each a PNG of the same pixels, written
// under dir; any other picture comes back as it is. When a tall picture cannot be cut (it will not
// decode, a slice will not write, or one would be over the picture limit) it also comes back whole,
// the cause is logged, and Telegram decides what to do with it.
func (a *app) splitTall(lim OutLimits, f LocalFile, dir string) []LocalFile {
	whole := []LocalFile{f}
	src, err := os.Open(f.Path)
	if err != nil {
		return whole
	}
	defer src.Close()
	cfg, _, err := image.DecodeConfig(src)
	cuts := sliceCuts(cfg.Width, cfg.Height)
	if err != nil || cuts == nil || cfg.Width*cfg.Height > maxSplitPx {
		return whole
	}
	fail := func(why error) []LocalFile {
		a.noteFailure("cutting tall picture "+f.Name, why.Error())
		return whole
	}
	if _, err = src.Seek(0, 0); err != nil {
		return fail(err)
	}
	img, _, err := image.Decode(src)
	if err != nil {
		return fail(err)
	}
	sub, ok := img.(interface {
		SubImage(image.Rectangle) image.Image
	})
	if !ok {
		return fail(fmt.Errorf("%T cannot be cut", img))
	}
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return fail(err)
	}
	b, base, slices := img.Bounds(), strings.TrimSuffix(f.Name, filepath.Ext(f.Name)), []LocalFile{}
	for i := 0; i+1 < len(cuts); i++ {
		name := base + "-" + strconv.Itoa(i+1) + ".png"
		p := filepath.Join(dir, name)
		out, err := os.Create(p)
		if err != nil {
			return fail(err)
		}
		err = png.Encode(out, sub.SubImage(image.Rect(b.Min.X, b.Min.Y+cuts[i], b.Max.X, b.Min.Y+cuts[i+1])))
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return fail(err)
		}
		if info, serr := os.Stat(p); serr != nil || info.Size() > lim.Photo {
			return fail(fmt.Errorf("slice %s is over the %d MB picture limit", name, lim.Photo>>20))
		}
		slices = append(slices, LocalFile{Path: p, Name: name, Photo: true})
	}
	return slices
}
