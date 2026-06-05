package vectorize

import (
	"math"
	"testing"

	"rinha-backend-2026/internal/model"
)

func TestVectorizeMatchesExample(t *testing.T) {
	v := New(Normalization{
		MaxAmount:            10000,
		MaxInstallments:      12,
		AmountVsAvgRatio:     10,
		MaxMinutes:           1440,
		MaxKm:                1000,
		MaxTxCount24h:        20,
		MaxMerchantAvgAmount: 10000,
	}, map[string]float32{
		"5912": 0.20,
	})

	vec, err := v.Vectorize(model.FraudScoreRequest{
		Transaction: model.Transaction{
			Amount:       41.12,
			Installments: 2,
			RequestedAt:  "2026-03-11T18:45:53Z",
		},
		Customer: model.Customer{
			AvgAmount:      82.24,
			TxCount24h:     3,
			KnownMerchants: []string{"MERC-003", "MERC-016"},
		},
		Merchant: model.Merchant{
			ID:        "MERC-016",
			MCC:       "5912",
			AvgAmount: 60.25,
		},
		Terminal: model.Terminal{
			IsOnline:    false,
			CardPresent: true,
			KMFromHome:  29.23,
		},
		LastTransaction: nil,
	})
	if err != nil {
		t.Fatalf("Vectorize() error = %v", err)
	}

	want := [14]float32{0.004112, 0.166667, 0.05, 0.782609, 0.333333, -1, -1, 0.02923, 0.15, 0, 1, 0, 0.20, 0.006025}
	for i := range want {
		if math.Abs(float64(vec[i]-want[i])) > 0.01 {
			t.Fatalf("vec[%d] = %f, want %f", i, vec[i], want[i])
		}
	}
}
