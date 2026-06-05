package vectorize

func Float32ToFloat16bitsForStorage(f float32) uint16 {
	return float32ToFloat16bits(f)
}

func Float16bitsToFloat32ForSearch(bits uint16) float32 {
	return float16bitsToFloat32(bits)
}
