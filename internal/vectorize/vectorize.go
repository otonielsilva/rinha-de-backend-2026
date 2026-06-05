package vectorize

import (
	"fmt"
	"math"
	"time"

	"rinha-backend-2026/internal/model"
)

type Normalization struct {
	MaxAmount            float32 `json:"max_amount"`
	MaxInstallments      float32 `json:"max_installments"`
	AmountVsAvgRatio     float32 `json:"amount_vs_avg_ratio"`
	MaxMinutes           float32 `json:"max_minutes"`
	MaxKm                float32 `json:"max_km"`
	MaxTxCount24h        float32 `json:"max_tx_count_24h"`
	MaxMerchantAvgAmount float32 `json:"max_merchant_avg_amount"`
}

type Vectorizer struct {
	norm    Normalization
	mccRisk map[string]float32
}

func New(norm Normalization, mccRisk map[string]float32) *Vectorizer {
	return &Vectorizer{norm: norm, mccRisk: mccRisk}
}

func (v *Vectorizer) Vectorize(req model.FraudScoreRequest) ([14]float32, error) {
	var out [14]float32

	requestedAt, err := parseTimestamp(req.Transaction.RequestedAt)
	if err != nil {
		return out, fmt.Errorf("transaction.requested_at: %w", err)
	}

	out[0] = clamp(normalize(float32(req.Transaction.Amount), v.norm.MaxAmount))
	out[1] = clamp(normalize(float32(req.Transaction.Installments), v.norm.MaxInstallments))
	out[2] = clamp(normalize(ratio(float32(req.Transaction.Amount), float32(req.Customer.AvgAmount)), v.norm.AmountVsAvgRatio))
	out[3] = float32(requestedAt.UTC().Hour()) / 23.0
	out[4] = float32(weekdayIndex(requestedAt.UTC().Weekday())) / 6.0

	if req.LastTransaction == nil {
		out[5] = -1
		out[6] = -1
	} else {
		lastAt, err := parseTimestamp(req.LastTransaction.Timestamp)
		if err != nil {
			return out, fmt.Errorf("last_transaction.timestamp: %w", err)
		}
		delta := requestedAt.Sub(lastAt)
		if delta < 0 {
			delta = 0
		}
		out[5] = clamp(normalize(float32(delta.Minutes()), v.norm.MaxMinutes))
		out[6] = clamp(normalize(float32(req.LastTransaction.KMFromCurrent), v.norm.MaxKm))
	}

	out[7] = clamp(normalize(float32(req.Terminal.KMFromHome), v.norm.MaxKm))
	out[8] = clamp(normalize(float32(req.Customer.TxCount24h), v.norm.MaxTxCount24h))
	if req.Terminal.IsOnline {
		out[9] = 1
	}
	if req.Terminal.CardPresent {
		out[10] = 1
	}
	if !contains(req.Customer.KnownMerchants, req.Merchant.ID) {
		out[11] = 1
	}
	if risk, ok := v.mccRisk[req.Merchant.MCC]; ok {
		out[12] = risk
	} else {
		out[12] = 0.5
	}
	out[13] = clamp(normalize(float32(req.Merchant.AvgAmount), v.norm.MaxMerchantAvgAmount))

	return out, nil
}

func parseTimestamp(raw string) (time.Time, error) {
	return time.Parse(time.RFC3339, raw)
}

func weekdayIndex(w time.Weekday) int {
	if w == time.Sunday {
		return 6
	}
	return int(w - time.Monday)
}

func normalize(value, max float32) float32 {
	if max <= 0 {
		return 0
	}
	return value / max
}

func ratio(numerator, denominator float32) float32 {
	if denominator <= 0 {
		return 0
	}
	return numerator / denominator
}

func clamp(v float32) float32 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	if math.IsNaN(float64(v)) {
		return 0
	}
	return v
}

func contains(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}
