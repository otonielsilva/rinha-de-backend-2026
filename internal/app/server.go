package app

import (
	"encoding/json"
	"io"
	"net/http"

	"rinha-backend-2026/internal/dataset"
	"rinha-backend-2026/internal/model"
	"rinha-backend-2026/internal/search"
	"rinha-backend-2026/internal/vectorize"
)

type Server struct {
	vectorizer *vectorize.Vectorizer
	searcher   *search.Searcher
}

func NewServer(resources *dataset.Resources) *Server {
	return &Server{
		vectorizer: vectorize.New(resources.Normalization, resources.MCCRisk),
		searcher:   search.New(resources.References),
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ready", s.ready)
	mux.HandleFunc("POST /fraud-score", s.fraudScore)
	return mux
}

func (s *Server) ready(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) fraudScore(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request", http.StatusBadRequest)
		return
	}

	var req model.FraudScoreRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	vec, err := s.vectorizer.Vectorize(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	score := s.searcher.Score(vec)
	resp := model.FraudScoreResponse{
		Approved:   score < 0.6,
		FraudScore: score,
	}

	w.Header().Set("Content-Type", "application/json")
	respBody, err := json.Marshal(resp)
	if err != nil {
		http.Error(w, "failed to encode response", http.StatusInternalServerError)
		return
	}
	_, _ = w.Write(respBody)
}
