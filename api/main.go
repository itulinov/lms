package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	// pgxpool читает PGHOST, PGPORT, PGUSER,
	// PGPASSWORD, PGDATABASE, PGSSLMODE.
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, "")
	if err != nil {
		log.Fatal("Failed to configure PostgreSQL connection")
	}
	defer pool.Close()

	mux := http.NewServeMux()

	// Проверка API и PostgreSQL
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		checkCtx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()

		w.Header().Set("Content-Type", "application/json; charset=utf-8")

		if err := pool.Ping(checkCtx); err != nil {
			log.Println("Database health check failed")

			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"status":   "error",
				"database": "unavailable",
			})
			return
		}

		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":   "ok",
			"database": "connected",
		})
	})

	// Информация о backend
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")

		_ = json.NewEncoder(w).Encode(map[string]string{
			"service":  "corporate-lms-api",
			"language": "go",
		})
	})

	log.Println("Go API listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}
