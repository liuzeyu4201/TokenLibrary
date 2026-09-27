package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"
	"tokenlibrary/internal/authn"
)

func main() {
	if err := run(os.Stdin, os.Stdout, os.Stderr, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func run(in *os.File, out, diagnostic io.Writer, args []string) error {
	flags := flag.NewFlagSet("hashcred", flag.ContinueOnError)
	flags.SetOutput(diagnostic)
	generateToken := flags.Bool("generate-upload-token", false, "also generate a random upload token and its SHA-256")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("passwords are read from the terminal or stdin; do not pass secrets as arguments")
	}
	var password []byte
	var err error
	if term.IsTerminal(int(in.Fd())) {
		fmt.Fprint(diagnostic, "Password (hidden): ")
		password, err = term.ReadPassword(int(in.Fd()))
		fmt.Fprintln(diagnostic)
		if err != nil {
			return err
		}
		fmt.Fprint(diagnostic, "Confirm password (hidden): ")
		confirmation, readErr := term.ReadPassword(int(in.Fd()))
		fmt.Fprintln(diagnostic)
		if readErr != nil {
			return readErr
		}
		if string(password) != string(confirmation) {
			return errors.New("password confirmation does not match")
		}
	} else {
		password, err = readPassword(in)
		if err != nil {
			return err
		}
	}
	if len(password) == 0 || len(password) > 4096 {
		return errors.New("password must contain 1 to 4096 bytes")
	}
	// Single quotes preserve every '$' when the generated line is pasted into Compose dotenv.
	fmt.Fprintf(out, "ADMIN_PASSWORD_HASH='%s'\n", authn.HashPassword(string(password)))
	if *generateToken {
		bytes := make([]byte, 32)
		if _, err := rand.Read(bytes); err != nil {
			return err
		}
		token := base64.RawURLEncoding.EncodeToString(bytes)
		sum := sha256.Sum256([]byte(token))
		fmt.Fprintln(out, "UPLOAD_TOKEN_HASH="+hex.EncodeToString(sum[:]))
		fmt.Fprintln(diagnostic, "Save this upload token in the caller's secret storage; only the hash belongs in .env:")
		fmt.Fprintln(diagnostic, token)
	}
	return nil
}

func readPassword(reader io.Reader) ([]byte, error) {
	line, err := bufio.NewReader(io.LimitReader(reader, 4098)).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	password := strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	if password == "" || len(password) > 4096 {
		return nil, errors.New("stdin must contain one password line of 1 to 4096 bytes")
	}
	return []byte(password), nil
}
