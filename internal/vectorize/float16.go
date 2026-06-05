package vectorize

import "math"

var float16LUT [65536]float32

func init() {
	for i := 0; i < 65536; i++ {
		float16LUT[i] = float16bitsToFloat32Slow(uint16(i))
	}
}

func float32ToFloat16bits(f float32) uint16 {
	bits := math.Float32bits(f)
	sign := uint16((bits >> 16) & 0x8000)
	exp := int((bits>>23)&0xff) - 127 + 15
	mant := bits & 0x7fffff

	switch {
	case exp <= 0:
		if exp < -10 {
			return sign
		}
		mant |= 0x800000
		shift := uint(1 - exp)
		rounded := mant >> (shift + 13)
		remainder := mant & ((1 << (shift + 13)) - 1)
		if remainder > (1<<(shift+12)) || (remainder == (1<<(shift+12)) && (rounded&1) == 1) {
			rounded++
		}
		return sign | uint16(rounded)
	case exp >= 0x1f:
		if mant == 0 {
			return sign | 0x7c00
		}
		return sign | 0x7c00 | uint16(mant>>13)
	default:
		rounded := mant >> 13
		if (mant & 0x1000) != 0 {
			rounded++
			if rounded == 0x400 {
				rounded = 0
				exp++
				if exp >= 0x1f {
					return sign | 0x7c00
				}
			}
		}
		return sign | uint16(exp<<10) | uint16(rounded)
	}
}

func float16bitsToFloat32(bits uint16) float32 {
	return float16LUT[bits]
}

func float16bitsToFloat32Slow(bits uint16) float32 {
	sign := uint32(bits&0x8000) << 16
	exp := (bits >> 10) & 0x1f
	mant := uint32(bits & 0x03ff)

	switch exp {
	case 0:
		if mant == 0 {
			return math.Float32frombits(sign)
		}
		e := int32(-14)
		for mant&0x0400 == 0 {
			mant <<= 1
			e--
		}
		mant &= 0x03ff
		return math.Float32frombits(sign | uint32((e+127)<<23) | (mant << 13))
	case 0x1f:
		return math.Float32frombits(sign | 0x7f800000 | (mant << 13))
	default:
		return math.Float32frombits(sign | uint32((int32(exp)-15+127)<<23) | (mant << 13))
	}
}
