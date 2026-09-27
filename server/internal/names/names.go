package names

import (
	"fmt"
	"path"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

func NameKey(name string) string {
	s := strings.TrimSpace(name)
	s = norm.NFC.String(s)
	s = cases.Fold().String(s)
	return s
}

func Validate(name string, isFolder bool) error {
	s := strings.TrimSpace(name)
	if s == "" || s == "." || s == ".." {
		return fmt.Errorf("invalid name")
	}
	if strings.ContainsAny(s, "/\\") || strings.ContainsRune(s, 0) {
		return fmt.Errorf("invalid name")
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return fmt.Errorf("invalid name")
		}
	}
	if utf8.RuneCountInString(s) == 0 || len(s) > 240 {
		return fmt.Errorf("invalid name")
	}
	return nil
}

// NextSuffix returns name with _N before extension. Example: 报告.pdf -> 报告_1.pdf
func NextSuffix(original string, taken map[string]bool) string {
	ext := path.Ext(original)
	base := strings.TrimSuffix(original, ext)
	for i := 1; i < 10000; i++ {
		cand := fmt.Sprintf("%s_%d%s", base, i, ext)
		if !taken[NameKey(cand)] {
			return cand
		}
	}
	return fmt.Sprintf("%s_%d%s", base, 10000, ext)
}

func SplitKindExt(filename string) (kind, mime string, ok bool) {
	lower := strings.ToLower(filename)
	switch {
	case strings.HasSuffix(lower, ".md"), strings.HasSuffix(lower, ".markdown"):
		return "md", "text/markdown", true
	case strings.HasSuffix(lower, ".pdf"):
		return "pdf", "application/pdf", true
	}
	return "", "", false
}
