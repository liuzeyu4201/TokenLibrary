package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"tokenlibrary/internal/authn"
)

func TestStdinPasswordDoesNotAppearInOutput(t *testing.T) {
	input, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	secret := "fixture-password-with-$-and-spaces"
	_, _ = input.WriteString(secret + "\n")
	_, _ = input.Seek(0, 0)
	var out, diagnostic bytes.Buffer
	if err := run(input, &out, &diagnostic, nil); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String()+diagnostic.String(), secret) {
		t.Fatal("password echoed")
	}
	hash := strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(out.String()), "ADMIN_PASSWORD_HASH='"), "'")
	if !authn.VerifyPassword(hash, secret) {
		t.Fatal("generated hash does not match stdin password")
	}
	if err := run(input, &out, &diagnostic, []string{secret}); err == nil {
		t.Fatal("password argument accepted")
	}
}

func TestPasswordInputValidation(t *testing.T) {
	for _, input := range []string{"", "\n", strings.Repeat("x", 4097)} {
		if _, err := readPassword(strings.NewReader(input)); err == nil {
			t.Fatal("invalid password accepted")
		}
	}
	password, err := readPassword(strings.NewReader(" leading and trailing spaces \r\n"))
	if err != nil || string(password) != " leading and trailing spaces " {
		t.Fatal("password characters changed")
	}
}
