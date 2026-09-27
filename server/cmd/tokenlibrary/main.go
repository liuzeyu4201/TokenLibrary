package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tokenlibrary/internal/api"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/jobs"
	"tokenlibrary/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	s, err := store.Connect(ctx, cfg)
	cancel()
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer s.Close()
	runner := &jobs.Runner{S: s}
	bg, stop := context.WithCancel(context.Background())
	go runner.Loop(bg)
	engine := api.New(cfg, s, runner)
	srv := &http.Server{Addr: cfg.ListenAddr, Handler: engine, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 2 * time.Minute, WriteTimeout: 5 * time.Minute, IdleTimeout: 90 * time.Second}
	go func() {
		log.Printf("tokenlibrary listening %s library=%s epoch=%s", cfg.ListenAddr, s.LibID, s.Epoch)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch
	stop()
	shctx, c2 := context.WithTimeout(context.Background(), 30*time.Second)
	defer c2()
	if err := srv.Shutdown(shctx); err != nil {
		log.Printf("http shutdown: %v", err)
		_ = srv.Close()
	}
}
