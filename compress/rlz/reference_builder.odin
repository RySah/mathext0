package rlz

import "core:mem"

Reference_Builder_Options :: struct {
    maximum_size: int,
    chunk_size:   int,
}

contains_chunk :: proc(reference: []u8, chunk: []u8) -> bool {
    if len(chunk) == 0 || len(chunk) > len(reference) { return false }
    for at in 0..=(len(reference)-len(chunk)) {
        match := true
        for i in 0..<len(chunk) {
            if reference[at+i] != chunk[i] { match = false; break }
        }
        if match { return true }
    }
    return false
}

// Selects unique chunks from every input in a deterministic round-robin order.
// Short final chunks are included, and output never exceeds maximum_size.
build_reference :: proc(inputs: [][]u8, options: Reference_Builder_Options = {}, allocator: mem.Allocator = context.allocator) -> []u8 {
    options := options
    if options.maximum_size <= 0 { options.maximum_size = 1_048_576 }
    if options.chunk_size <= 0 { options.chunk_size = 256 }
    result := make([dynamic]u8, 0, min(options.maximum_size, 4096), allocator)
    if len(inputs) == 0 { return result[:] }

    positions := make([]int, len(inputs), context.temp_allocator)
    active := true
    for active && len(result) < options.maximum_size {
        active = false
        for input, index in inputs {
            if positions[index] >= len(input) { continue }
            active = true
            count := min(options.chunk_size, len(input)-positions[index])
            chunk := input[positions[index]:positions[index]+count]
            positions[index] += count
            if !contains_chunk(result[:], chunk) {
                remaining := options.maximum_size-len(result)
                append(&result, ..chunk[:min(len(chunk), remaining)])
            }
            if len(result) >= options.maximum_size { break }
        }
    }
    return result[:]
}
