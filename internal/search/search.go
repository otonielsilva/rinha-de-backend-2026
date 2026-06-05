package search

import (
	"rinha-backend-2026/internal/dataset"
	"rinha-backend-2026/internal/vectorize"
)

type Searcher struct {
	references *dataset.References
}

func New(references *dataset.References) *Searcher {
	return &Searcher{references: references}
}

func (s *Searcher) Score(query [14]float32) float32 {
	if s.references.Count == 0 {
		return 0
	}

	var bestDist [5]float32
	var bestLabel [5]uint8
	count := 0
	for i := range bestDist {
		bestDist[i] = maxFloat32
	}

	indices := s.references.SampledIndices
	if len(indices) == 0 {
		indices = make([]int, s.references.Count)
		for i := 0; i < s.references.Count; i++ {
			indices[i] = i
		}
	}

	for _, idx := range indices {
		base := idx * s.references.Dim
		dist := float32(0)
		threshold := bestDist[4] // avoid repeated array access

		for d := 0; d < s.references.Dim; d++ {
			diff := query[d] - vectorize.Float16bitsToFloat32ForSearch(s.references.Vectors[base+d])
			dist += diff * diff
			if dist >= threshold {
				break
			}
		}

		if dist >= threshold && count == 5 {
			continue
		}

		label := s.references.Labels[idx]
		if count < 5 {
			pos := count
			count++
			for pos > 0 && dist < bestDist[pos-1] {
				bestDist[pos] = bestDist[pos-1]
				bestLabel[pos] = bestLabel[pos-1]
				pos--
			}
			bestDist[pos] = dist
			bestLabel[pos] = label
		} else {
			pos := 4
			if dist < bestDist[4] {
				for pos > 0 && dist < bestDist[pos-1] {
					bestDist[pos] = bestDist[pos-1]
					bestLabel[pos] = bestLabel[pos-1]
					pos--
				}
				bestDist[pos] = dist
				bestLabel[pos] = label
			}
		}
	}

	frauds := 0
	for i := 0; i < count; i++ {
		frauds += int(bestLabel[i])
	}
	return float32(frauds) / 5.0
}

const maxFloat32 = 3.4028235e+38
