package authn

import (
	"errors"
	"sync"
	"testing"
	"time"
)

func TestLoginGateRejectsExcessFailuresAndConcurrentVerifies(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	gate := NewLoginGate(func() time.Time { return now })
	for i := 0; i < LoginFailureLimit; i++ {
		if err := gate.Acquire("203.0.113.8"); err != nil {
			t.Fatalf("attempt %d: %v", i+1, err)
		}
		gate.Release("203.0.113.8", true)
	}
	if err := gate.Acquire("203.0.113.8"); !errors.Is(err, ErrTooManyAttempts) {
		t.Fatalf("eleventh attempt: %v", err)
	}
	now = now.Add(LoginFailureWindow + time.Second)
	if err := gate.Acquire("203.0.113.8"); err != nil {
		t.Fatal(err)
	}
	gate.Release("203.0.113.8", false)

	held := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < LoginVerifySlots; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := gate.Acquire("198.51.100.4"); err != nil {
				t.Errorf("slot: %v", err)
				return
			}
			held <- struct{}{}
			<-release
			gate.Release("198.51.100.4", false)
		}()
	}
	for i := 0; i < LoginVerifySlots; i++ {
		<-held
	}
	if err := gate.Acquire("198.51.100.4"); !errors.Is(err, ErrVerifyBusy) {
		t.Fatalf("third verification: %v", err)
	}
	close(release)
	wg.Wait()
	if err := gate.Acquire("198.51.100.4"); err != nil {
		t.Fatal(err)
	}
	gate.Release("198.51.100.4", false)
}
