package rlz

import "core:mem"
import "core:sort"

Reference_Index :: struct {
    reference: []u8,
    suffixes:  []int,
}

Suffix_Sort :: struct {
    reference: []u8,
    suffixes:  []int,
}

index_create :: proc(reference: []u8, allocator: mem.Allocator = context.allocator) -> Reference_Index {
    idx := Reference_Index{reference = reference}
    if len(reference) == 0 { return idx }
    idx.suffixes = make([]int, len(reference), allocator)
    for i in 0..<len(reference) { idx.suffixes[i] = i }
    work := Suffix_Sort{reference, idx.suffixes}
    interface := sort.Interface{
        collection = rawptr(&work),
        len = proc(it: sort.Interface) -> int {
            s := (^Suffix_Sort)(it.collection)
            return len(s.suffixes)
        },
        less = proc(it: sort.Interface, i, j: int) -> bool {
            s := (^Suffix_Sort)(it.collection)
            a, b := s.suffixes[i], s.suffixes[j]
            for {
                if a >= len(s.reference) { return b < len(s.reference) }
                if b >= len(s.reference) { return false }
                if s.reference[a] != s.reference[b] {
                    return s.reference[a] < s.reference[b]
                }
                a += 1
                b += 1
            }
        },
        swap = proc(it: sort.Interface, i, j: int) {
            s := (^Suffix_Sort)(it.collection)
            s.suffixes[i], s.suffixes[j] = s.suffixes[j], s.suffixes[i]
        },
    }
    sort.sort(interface)
    return idx
}

index_destroy :: proc(index: ^Reference_Index) {
    if index == nil { return }
    delete(index.suffixes)
    index^ = {}
}

compare_suffix :: proc(reference, pattern: []u8, suffix: int) -> int {
    at := suffix
    n := 0
    for at < len(reference) && n < len(pattern) {
        if reference[at] < pattern[n] { return -1 }
        if reference[at] > pattern[n] { return 1 }
        at += 1
        n += 1
    }
    if n == len(pattern) { return 0 }
    return -1
}

match_at :: proc(reference, input: []u8, reference_at, input_at: int) -> int {
    n := 0
    for reference_at+n < len(reference) && input_at+n < len(input) &&
        reference[reference_at+n] == input[input_at+n] {
        n += 1
    }
    return n
}

longest_match :: proc(index: ^Reference_Index, input: []u8, input_at: int) -> (source_at, length: int) {
    if index == nil || len(index.suffixes) == 0 || input_at >= len(input) {
        return 0, 0
    }
    pattern := input[input_at:]
    lo, hi := 0, len(index.suffixes)
    for lo < hi {
        mid := lo + (hi-lo)/2
        if compare_suffix(index.reference, pattern, index.suffixes[mid]) < 0 {
            lo = mid+1
        } else {
            hi = mid
        }
    }
    first := max(lo-1, 0)
    last := min(lo+1, len(index.suffixes)-1)
    for i in first..=last {
        candidate := index.suffixes[i]
        n := match_at(index.reference, input, candidate, input_at)
        if n > length || (n == length && candidate < source_at) {
            source_at, length = candidate, n
        }
    }
    return
}

matching_statistics :: proc(index: ^Reference_Index, input: []u8, allocator: mem.Allocator = context.allocator) -> ([]int, []int) {
    ptrs := make([]int, len(input), allocator)
    lens := make([]int, len(input), allocator)
    for i in 0..<len(input) {
        ptrs[i], lens[i] = longest_match(index, input, i)
    }
    return ptrs, lens
}
