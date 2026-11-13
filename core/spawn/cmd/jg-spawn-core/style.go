package main

import (
	"fmt"
	"os"
	"strings"
)

// styleIs reports whether a delivery-style fact (publishes, review or trunk) is yes for a mode word. It reads the same table as
// bin/jg-delivery-style.sh: the wrapper bin/jg-spawn-core.sh exports its path as JG_DELIVERY_STYLES. An old word reads as the style
// of its alias row and keeps the trunk fact the alias row carries. An unreadable table or an unknown word is an error with its cause.
func styleIs(mode, fact string) (bool, error) {
	path := os.Getenv("JG_DELIVERY_STYLES")
	if path == "" {
		return false, fmt.Errorf("JG_DELIVERY_STYLES is not set: run the spawn core through bin/jg-spawn-core.sh")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false, fmt.Errorf("delivery-style table not readable: %v", err)
	}
	cols := map[string]int{}
	style, aliasTrunk := mode, ""
	rows := map[string][]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Split(line, "\t")
		switch f[0] {
		case "columns":
			for i, name := range f[1:] {
				cols[name] = i + 1
			}
		case "style":
			rows[f[1]] = f
		case "alias":
			if f[1] == mode && len(f) > 3 {
				style, aliasTrunk = f[2], f[3]
			}
		}
	}
	row, ok := rows[style]
	i, known := cols[fact]
	if !ok || !known || i >= len(row) {
		return false, fmt.Errorf("delivery-style table has no %q fact for mode %q", fact, mode)
	}
	if fact == "trunk" && aliasTrunk != "" {
		return aliasTrunk == "yes", nil
	}
	return row[i] == "yes", nil
}
