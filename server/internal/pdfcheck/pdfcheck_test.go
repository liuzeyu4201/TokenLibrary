package pdfcheck

import "testing"

func TestPasswordProtectedPDFIsMarked(t *testing.T) {
	plain := []byte("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")
	locked := []byte("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R /Encrypt 2 0 R >>\n2 0 obj << /Filter /Standard >> endobj\n%%EOF\n")
	if got := Classify(plain); !got.PDF || got.PasswordRequired {
		t.Fatalf("plain pdf: %+v", got)
	}
	if got := Classify(locked); !got.PDF || !got.PasswordRequired {
		t.Fatalf("locked pdf: %+v", got)
	}
	if got := Classify([]byte("not a pdf")); got.PDF || got.PasswordRequired {
		t.Fatalf("non pdf: %+v", got)
	}
}
