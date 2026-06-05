package search

import (
	"testing"

	"rinha-backend-2026/internal/dataset"
	"rinha-backend-2026/internal/vectorize"
)

func TestScoreCountsFraudAmongNearestFive(t *testing.T) {
	refs := &dataset.References{
		Dim:     14,
		Count:   5,
		Vectors: make([]uint16, 5*14),
		Labels:  []uint8{1, 0, 1, 0, 1},
	}

	base := [14]float32{0.1, 0.2, 0.05, 0.3, 0.4, -1, -1, 0.1, 0.2, 0, 1, 0, 0.2, 0.1}
	for i := 0; i < 5; i++ {
		for d := 0; d < 14; d++ {
			refs.Vectors[i*14+d] = vectorize.Float32ToFloat16bitsForStorage(base[d] + float32(i)*0.001)
		}
	}

	score := New(refs).Score(base)
	if score != 0.6 {
		t.Fatalf("Score() = %v, want 0.6", score)
	}
}
