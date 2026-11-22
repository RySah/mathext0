package bitvec

import "core:math/bits"

// Counts set bits in positions [0, v).
rank :: #force_inline proc(vec: $T, v: uint) -> T {
    return bits.count_ones(bits.bitfield_extract(vec, 0, v))
}

// Returns the zero-based position of the ith set bit.
// i is 1-based, matching RLZ notation.
//
// Returns false if the requested set bit does not exist.
select :: #force_inline proc(vec: $T, i: uint) -> (position: uint, ok: bool) {
    if i == 0 || i > uint(bits.count_ones(vec)) {
        return 0, false
    }

    x := vec

    // Remove the first i-1 set bits.
    for j: uint = 1; j < i; j += 1 {
        x &= x - 1
    }

    return uint(bits.count_trailing_zeros(x)), true
}