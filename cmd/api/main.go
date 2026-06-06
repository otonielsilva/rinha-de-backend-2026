package main

import (
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"time"

	"rinha-backend-2026/internal/app"
	"rinha-backend-2026/internal/dataset"
)

func main() {
	runtime.GOMAXPROCS(1)
	prev := debug.SetGCPercent(-1)
	log.Printf("worker-pool: GOMAXPROCS=1, GOGC=off (was %d), GOMEMLIMIT=%s", prev, os.Getenv("GOMEMLIMIT"))

	resourceDir, err := discoverResourceDir()
	if err != nil {
		log.Fatal(err)
	}

	resources, err := dataset.Load(resourceDir, os.Getenv("RINHA_CACHE_DIR"))
	if err != nil {
		log.Fatalf("load resources: %v", err)
	}

	server := app.NewServer(resources)
	if os.Getenv("RINHA_WARMUP_ONLY") == "1" {
		log.Printf("warmup complete for resources at %s", resourceDir)
		return
	}

	httpServer := &http.Server{
		Addr:              ":9999",
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	// uds-nginx: also listen on Unix socket if configured (for low-latency
	// nginx communication). Always listen on TCP :9999 for health checks.
	if sockPath := os.Getenv("RINHA_LISTEN_UNIX"); sockPath != "" {
		_ = os.Remove(sockPath)
		ln, err := net.Listen("unix", sockPath)
		if err != nil {
			log.Fatalf("listen unix %s: %v", sockPath, err)
		}
		_ = os.Chmod(sockPath, 0o666)
		log.Printf("uds-nginx: also listening on unix://%s", sockPath)
		go func() {
			log.Fatal(httpServer.Serve(ln))
		}()
	}

	log.Printf("api listening on %s using resources at %s", httpServer.Addr, resourceDir)
	log.Fatal(httpServer.ListenAndServe())
}

func discoverResourceDir() (string, error) {
	if dir := os.Getenv("RINHA_RESOURCES_DIR"); dir != "" {
		return dir, nil
	}

	candidates := []string{
		"/app/resources",
		"./resources",
		".",
		"/resources",
	}
	for _, dir := range candidates {
		if exists(filepath.Join(dir, "normalization.json")) {
			return dir, nil
		}
	}

	return "./resources", nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
