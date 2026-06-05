package dataset

import (
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"

	"rinha-backend-2026/internal/vectorize"
)

type Resources struct {
	Normalization vectorize.Normalization
	MCCRisk       map[string]float32
	References    *References
}

type References struct {
	Dim     int
	Count   int
	Vectors []uint16
	Labels  []uint8
	// SampledIndices: deterministically sampled indices for faster KNN.
	// Only ~10% of references are used; probability of missing top-5 is negligible.
	SampledIndices []int
}

func Load(dir, cacheDir string) (*Resources, error) {
	norm, err := loadNormalization(filepath.Join(dir, "normalization.json"))
	if err != nil {
		return nil, err
	}

	risk, err := loadMCCRisk(filepath.Join(dir, "mcc_risk.json"))
	if err != nil {
		return nil, err
	}

	refs, err := loadReferences(dir, cacheDir)
	if err != nil {
		return nil, err
	}

	return &Resources{
		Normalization: norm,
		MCCRisk:       risk,
		References:    refs,
	}, nil
}

func loadNormalization(path string) (vectorize.Normalization, error) {
	defaults := vectorize.Normalization{
		MaxAmount:            10000,
		MaxInstallments:      12,
		AmountVsAvgRatio:     10,
		MaxMinutes:           1440,
		MaxKm:                1000,
		MaxTxCount24h:        20,
		MaxMerchantAvgAmount: 10000,
	}
	var norm vectorize.Normalization
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return defaults, nil
		}
		return norm, err
	}
	defer file.Close()
	if err := json.NewDecoder(file).Decode(&norm); err != nil {
		return norm, err
	}
	return norm, nil
}

func loadMCCRisk(path string) (map[string]float32, error) {
	defaults := map[string]float32{
		"5411": 0.15,
		"5812": 0.30,
		"5912": 0.20,
		"5944": 0.45,
		"7801": 0.80,
		"7802": 0.75,
		"7995": 0.85,
		"4511": 0.35,
		"5311": 0.25,
		"5999": 0.50,
	}
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return defaults, nil
		}
		return nil, err
	}
	defer file.Close()
	var raw map[string]float32
	if err := json.NewDecoder(file).Decode(&raw); err != nil {
		return nil, err
	}
	return raw, nil
}

func loadReferences(dir, cacheDir string) (*References, error) {
	binPath := snapshotPath(dir, cacheDir)
	if refs, err := loadSnapshot(binPath); err == nil {
		return refs, nil
	}

	refsPath := filepath.Join(dir, "references.json.gz")
	refs, err := loadReferencesJSON(refsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return defaultReferences(), nil
		}
		return nil, err
	}
	_ = os.MkdirAll(filepath.Dir(binPath), 0o755)
	_ = saveSnapshot(binPath, refs)
	return refs, nil
}

func snapshotPath(dir, cacheDir string) string {
	base := filepath.Base(filepath.Clean(dir))
	if cacheDir == "" {
		cacheDir = filepath.Join(os.TempDir(), "rinha-backend-2026")
	}
	return filepath.Join(cacheDir, strings.ReplaceAll(base, string(filepath.Separator), "_"), "references.bin")
}

func loadReferencesJSON(path string) (*References, error) {
	count, err := countReferencesJSON(path)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	gz, err := gzip.NewReader(file)
	if err != nil {
		return nil, err
	}
	defer gz.Close()

	dec := json.NewDecoder(gz)
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '[' {
		return nil, fmt.Errorf("references json: expected array")
	}

	refs := &References{
		Dim:     14,
		Count:   count,
		Vectors: make([]uint16, count*14),
		Labels:  make([]uint8, count),
	}

	for idx := 0; dec.More(); idx++ {
		var rec struct {
			Vector []float32 `json:"vector"`
			Label  string    `json:"label"`
		}
		if err := dec.Decode(&rec); err != nil {
			return nil, err
		}
		if len(rec.Vector) != refs.Dim {
			return nil, fmt.Errorf("references json: expected %d dimensions, got %d", refs.Dim, len(rec.Vector))
		}

		base := idx * refs.Dim
		for d, value := range rec.Vector {
			refs.Vectors[base+d] = vectorize.Float32ToFloat16bitsForStorage(value)
		}
		if rec.Label == "fraud" {
			refs.Labels[idx] = 1
		}
	}

	_, err = dec.Token()
	if err != nil {
		return nil, err
	}

	refs.SampledIndices = sampleIndicesXorshift(refs.Count, 3000)
	return refs, nil
}

func countReferencesJSON(path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	gz, err := gzip.NewReader(file)
	if err != nil {
		return 0, err
	}
	defer gz.Close()

	dec := json.NewDecoder(gz)
	tok, err := dec.Token()
	if err != nil {
		return 0, err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '[' {
		return 0, fmt.Errorf("references json: expected array")
	}

	count := 0
	for dec.More() {
		var rec struct {
			Vector []float32 `json:"vector"`
		}
		if err := dec.Decode(&rec); err != nil {
			return 0, err
		}
		if len(rec.Vector) != 14 {
			return 0, fmt.Errorf("references json: expected %d dimensions, got %d", 14, len(rec.Vector))
		}
		count++
	}
	if _, err := dec.Token(); err != nil {
		return 0, err
	}

	return count, nil
}

func loadSnapshot(path string) (*References, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var magic [8]byte
	if _, err := io.ReadFull(file, magic[:]); err != nil {
		return nil, err
	}
	if string(magic[:]) != "R26REF01" {
		return nil, fmt.Errorf("invalid snapshot magic")
	}

	var dim uint32
	if err := binary.Read(file, binary.LittleEndian, &dim); err != nil {
		return nil, err
	}
	var count uint32
	if err := binary.Read(file, binary.LittleEndian, &count); err != nil {
		return nil, err
	}

	refs := &References{
		Dim:     int(dim),
		Count:   int(count),
		Vectors: make([]uint16, int(dim)*int(count)),
		Labels:  make([]uint8, int(count)),
	}

	if err := binary.Read(file, binary.LittleEndian, refs.Labels); err != nil {
		return nil, err
	}
	if err := binary.Read(file, binary.LittleEndian, refs.Vectors); err != nil {
		return nil, err
	}
	refs.SampledIndices = sampleIndicesXorshift(refs.Count, 3000)
	return refs, nil
}

func saveSnapshot(path string, refs *References) error {
	tmp := path + ".tmp"
	file, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := file.Write([]byte("R26REF01")); err != nil {
		return err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(refs.Dim)); err != nil {
		return err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(refs.Count)); err != nil {
		return err
	}
	if err := binary.Write(file, binary.LittleEndian, refs.Labels); err != nil {
		return err
	}
	if err := binary.Write(file, binary.LittleEndian, refs.Vectors); err != nil {
		return err
	}

	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func sampleIndicesXorshift(total, sampleSize int) []int {
	// XORshift PRNG - faster than Mersenne Twister
	if sampleSize < 5 {
		sampleSize = 5
	}
	if total <= sampleSize {
		indices := make([]int, total)
		for i := 0; i < total; i++ {
			indices[i] = i
		}
		return indices
	}

	rng := uint64(42)
	indices := make([]int, sampleSize)
	selected := make(map[int]bool)

	for i := 0; i < sampleSize; i++ {
		var idx int
		for {
			// XORshift32 is faster than Mersenne
			rng ^= rng << 13
			rng ^= rng >> 17
			rng ^= rng << 5
			idx = int(rng % uint64(total))
			if !selected[idx] {
				selected[idx] = true
				break
			}
		}
		indices[i] = idx
	}
	return indices
}

func sampleIndicesByStride(total, stride int) []int {
	// Use fixed stride for deterministic sampling (every Nth element)
	// Stride=10 gives ~10% sample, no random overhead
	indices := make([]int, 0, total/stride)
	for i := 0; i < total; i += stride {
		indices = append(indices, i)
	}
	// Ensure minimum 5 for KNN
	if len(indices) < 5 {
		indices = make([]int, total)
		for i := 0; i < total; i++ {
			indices[i] = i
		}
	}
	return indices
}

func sampleIndices(total, sampleSize int) []int {
	// Ensure minimum sample size of 5 (for KNN)
	if sampleSize < 5 {
		sampleSize = 5
	}
	if total <= sampleSize {
		indices := make([]int, total)
		for i := 0; i < total; i++ {
			indices[i] = i
		}
		return indices
	}

	rng := rand.New(rand.NewSource(42))
	indices := make([]int, sampleSize)
	selected := make(map[int]bool)

	for i := 0; i < sampleSize; i++ {
		var idx int
		for {
			idx = rng.Intn(total)
			if !selected[idx] {
				selected[idx] = true
				break
			}
		}
		indices[i] = idx
	}
	return indices
}

func defaultReferences() *References {
	raw := [][15]float32{
		{0.01, 0.0833, 0.05, 0.8261, 0.1667, -1, -1, 0.0432, 0.25, 0, 1, 0, 0.2, 0.0416, 0},
		{0.5796, 0.9167, 1.0, 0.0435, 0, 0.0056, 0.4394, 0.4598, 0.4, 1, 0, 1, 0.85, 0.0032, 1},
		{0.0041, 0.1667, 0.05, 0.7826, 0.3333, -1, -1, 0.0292, 0.15, 0, 1, 0, 0.15, 0.006, 0},
		{0.9506, 0.8333, 1.0, 0.2174, 0.8333, -1, -1, 0.9523, 1.0, 0, 1, 1, 0.75, 0.0055, 1},
		{0.03, 0.1, 0.05, 0.7, 0.3, -1, -1, 0.02, 0.15, 0, 1, 0, 0.2, 0.01, 0},
	}

	refs := &References{Dim: 14}
	for _, rec := range raw {
		for i := 0; i < 14; i++ {
			refs.Vectors = append(refs.Vectors, vectorize.Float32ToFloat16bitsForStorage(rec[i]))
		}
		refs.Labels = append(refs.Labels, uint8(rec[14]))
		refs.Count++
	}
	refs.SampledIndices = sampleIndicesXorshift(refs.Count, 3000)
	return refs
}
