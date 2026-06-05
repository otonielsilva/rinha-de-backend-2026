package app

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"rinha-backend-2026/internal/dataset"
)

func TestFraudScoreAPI(t *testing.T) {
	dir := t.TempDir()
	writeFixture(t, dir)

	resources, err := dataset.Load(dir, filepath.Join(dir, "cache"))
	if err != nil {
		t.Fatalf("dataset.Load() error = %v", err)
	}

	srv := NewServer(resources)
	handler := srv.Handler()

	readyReq := httptest.NewRequest("GET", "/ready", nil)
	readyRec := httptest.NewRecorder()
	handler.ServeHTTP(readyRec, readyReq)
	if readyRec.Code/100 != 2 {
		t.Fatalf("/ready status = %d, want 2xx", readyRec.Code)
	}

	var out struct {
		Approved   bool    `json:"approved"`
		FraudScore float32 `json:"fraud_score"`
	}

	body := []byte(`{"id":"tx-1","transaction":{"amount":100,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":200,"tx_count_24h":3,"known_merchants":["MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5912","avg_amount":60},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.23},"last_transaction":null}`)
	scoreReq := httptest.NewRequest("POST", "/fraud-score", bytes.NewReader(body))
	scoreRec := httptest.NewRecorder()
	handler.ServeHTTP(scoreRec, scoreReq)

	if scoreRec.Code != 200 {
		t.Fatalf("status = %d, want 200", scoreRec.Code)
	}

	if err := json.NewDecoder(scoreRec.Body).Decode(&out); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !out.Approved {
		t.Fatalf("approved = false, want true")
	}
	if out.FraudScore != 0.4 {
		t.Fatalf("fraud_score = %v, want 0.4", out.FraudScore)
	}
}

func writeFixture(t *testing.T, dir string) {
	t.Helper()

	mustWriteJSON(t, filepath.Join(dir, "normalization.json"), map[string]float32{
		"max_amount":              10000,
		"max_installments":        12,
		"amount_vs_avg_ratio":     10,
		"max_minutes":             1440,
		"max_km":                  1000,
		"max_tx_count_24h":        20,
		"max_merchant_avg_amount": 10000,
	})
	mustWriteJSON(t, filepath.Join(dir, "mcc_risk.json"), map[string]float32{"5912": 0.2})

	var refs bytes.Buffer
	gw := gzip.NewWriter(&refs)
	_, _ = gw.Write([]byte(`[`))
	entries := []struct {
		Vector [14]float32 `json:"vector"`
		Label  string      `json:"label"`
	}{
		{Vector: [14]float32{0.01, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01}, Label: "legit"},
		{Vector: [14]float32{0.02, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01}, Label: "legit"},
		{Vector: [14]float32{0.03, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01}, Label: "fraud"},
		{Vector: [14]float32{0.04, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01}, Label: "fraud"},
		{Vector: [14]float32{0.05, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01}, Label: "legit"},
	}
	for i, e := range entries {
		raw, _ := json.Marshal(e)
		if i > 0 {
			_, _ = gw.Write([]byte(","))
		}
		_, _ = gw.Write(raw)
	}
	_, _ = gw.Write([]byte(`]`))
	if err := gw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "references.json.gz"), refs.Bytes(), 0o644); err != nil {
		t.Fatalf("write references: %v", err)
	}
}

func mustWriteJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatalf("write json: %v", err)
	}
}
