package authn

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	h := HashPassword("local-dev-pass")
	if !VerifyPassword(h, "local-dev-pass") {
		t.Fatal("verify failed")
	}
	if VerifyPassword(h, "nope") {
		t.Fatal("false positive")
	}
}
