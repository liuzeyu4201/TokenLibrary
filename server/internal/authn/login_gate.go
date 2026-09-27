package authn

import (
	"errors"
	"sync"
	"time"
)

const (
	LoginFailureLimit = 10
	LoginFailureWindow = 15 * time.Minute
	LoginVerifySlots = 2
)

var (
	ErrTooManyAttempts = errors.New("too many login attempts")
	ErrVerifyBusy      = errors.New("password verification busy")
)

// LoginGate limits failed attempts per address and how many password checks run at once.
type LoginGate struct {
	now      func() time.Time
	mu       sync.Mutex
	failures map[string][]time.Time
	active   int
}

func NewLoginGate(now func() time.Time) *LoginGate {
	if now == nil {
		now = time.Now
	}
	return &LoginGate{now: now, failures: map[string][]time.Time{}}
}

func (g *LoginGate) Acquire(ip string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prune(ip)
	if len(g.failures[ip]) >= LoginFailureLimit {
		return ErrTooManyAttempts
	}
	if g.active >= LoginVerifySlots {
		return ErrVerifyBusy
	}
	g.active++
	return nil
}

func (g *LoginGate) Release(ip string, failed bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.active > 0 {
		g.active--
	}
	if failed {
		g.failures[ip] = append(g.failures[ip], g.now())
		g.prune(ip)
	}
}

func (g *LoginGate) prune(ip string) {
	cutoff := g.now().Add(-LoginFailureWindow)
	kept := g.failures[ip][:0]
	for _, at := range g.failures[ip] {
		if !at.Before(cutoff) {
			kept = append(kept, at)
		}
	}
	if len(kept) == 0 {
		delete(g.failures, ip)
		return
	}
	g.failures[ip] = kept
}
