package api

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

type changeNote struct {
	Type           string `json:"type"`
	Epoch          string `json:"epoch"`
	LatestSequence int64  `json:"latestSequence"`
}

type changeHub struct {
	mu   sync.Mutex
	subs map[chan changeNote]struct{}
}

func newChangeHub() *changeHub {
	return &changeHub{subs: map[chan changeNote]struct{}{}}
}

func (h *changeHub) subscribe() chan changeNote {
	ch := make(chan changeNote, 8)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *changeHub) unsubscribe(ch chan changeNote) {
	h.mu.Lock()
	delete(h.subs, ch)
	h.mu.Unlock()
}

func (h *changeHub) Publish(note changeNote) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- note:
		default:
		}
	}
}

var wsUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func (s *Server) ws(c *gin.Context) {
	conn, err := wsUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	notes := s.Hub.subscribe()
	defer s.Hub.unsubscribe(notes)
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn.SetReadLimit(1024)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
		conn.SetPongHandler(func(string) error {
			return conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
		})
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()
	for {
		select {
		case <-done:
			return
		case note := <-notes:
			_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := conn.WriteJSON(note); err != nil {
				return
			}
		}
	}
}
