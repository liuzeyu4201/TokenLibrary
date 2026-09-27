package pdfcheck

import "bytes"

type Classification struct {
	PDF              bool
	PasswordRequired bool
}

// Classify recognizes a PDF header and an encryption dictionary.
// It does not decrypt the file or rewrite the caller's bytes.
func Classify(data []byte) Classification {
	if !bytes.Contains(data, []byte("%PDF-")) {
		return Classification{}
	}
	return Classification{PDF: true, PasswordRequired: bytes.Contains(data, []byte("/Encrypt"))}
}
