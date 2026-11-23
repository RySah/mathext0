package rlz

import "core:mem"
import "core:sort"

Reference_Strategy :: enum {
	Automatic,
	Representative_Sampling,
	Frequent_Substrings,
	Coverage_Optimized,
}

Reference_Options :: struct {
	max_size: int,
	strategy: Reference_Strategy,
}

// Kept for callers of the original, single-strategy builder.
Reference_Builder_Options :: struct {
	maximum_size: int,
	chunk_size:   int,
}

Reference_Candidate :: struct {
	input_index: int,
	at:          int,
	length:      int,
	count:       int,
	input_count: int,
	last_input:  int,
}

Reference_Hash :: struct {
	first:  u64,
	second: u64,
}

Reference_Candidate_Sort :: struct {
	inputs:     [][]u8,
	candidates: []Reference_Candidate,
	coverage:   bool,
}

Coverage_Set :: struct {
	keys:     []Reference_Hash,
	occupied: []bool,
	allocator: mem.Allocator,
}

contains_chunk :: proc(reference, chunk: []u8) -> bool {
	if len(chunk) == 0 || len(chunk) > len(reference) { return false }
	for at in 0..=(len(reference)-len(chunk)) {
		match := true
		for i in 0..<len(chunk) {
			if reference[at+i] != chunk[i] {
				match = false
				break
			}
		}
		if match { return true }
	}
	return false
}

candidate_less :: proc(a, b: Reference_Candidate, inputs: [][]u8, coverage: bool) -> bool {
	af, bf: i64
	af = i64(a.count)*i64(a.length)
	bf = i64(b.count)*i64(b.length)
	if coverage {
		af *= i64(a.input_count)
		bf *= i64(b.input_count)
	}
	if af != bf { return af > bf }
	if a.input_index != b.input_index { return a.input_index < b.input_index }
	if a.at != b.at { return a.at < b.at }
	aa := inputs[a.input_index][a.at:a.at+a.length]
	bb := inputs[b.input_index][b.at:b.at+b.length]
	return bytes_less(aa, bb)
}

bytes_less :: proc(a, b: []u8) -> bool {
	limit := min(len(a), len(b))
	for i in 0..<limit {
		if a[i] != b[i] { return a[i] < b[i] }
	}
	return len(a) < len(b)
}

sort_reference_candidates :: proc(inputs: [][]u8, candidates: [dynamic]Reference_Candidate, coverage: bool) {
	if len(candidates) < 2 { return }
	work := Reference_Candidate_Sort{inputs, candidates[:], coverage}
	interface := sort.Interface{
		collection = rawptr(&work),
		len = proc(it: sort.Interface) -> int {
			s := (^Reference_Candidate_Sort)(it.collection)
			return len(s.candidates)
		},
		less = proc(it: sort.Interface, i, j: int) -> bool {
			s := (^Reference_Candidate_Sort)(it.collection)
			return candidate_less(s.candidates[i], s.candidates[j], s.inputs, s.coverage)
		},
		swap = proc(it: sort.Interface, i, j: int) {
			s := (^Reference_Candidate_Sort)(it.collection)
			s.candidates[i], s.candidates[j] = s.candidates[j], s.candidates[i]
		},
	}
	sort.sort(interface)
}

reference_window_hash :: proc(data: []u8) -> Reference_Hash {
	first := u64(0xcbf29ce484222325)
	second := u64(0x84222325cbf29ce4)
	for byte in data {
		first = (first ~ u64(byte))*0x100000001b3
		second = (second + u64(byte)+u64(0x9e3779b97f4a7c15))*0x9e3779b185ebca87
		second = (second << 17) | (second >> 47)
	}
	return {first, second}
}

same_candidate_bytes :: proc(inputs: [][]u8, candidate: Reference_Candidate, data: []u8) -> bool {
	if candidate.input_index < 0 || candidate.input_index >= len(inputs) ||
	   candidate.at < 0 || candidate.at > len(inputs[candidate.input_index])-len(data) {
		return false
	}
	existing := inputs[candidate.input_index][candidate.at:candidate.at+len(data)]
	for byte, i in data {
		if existing[i] != byte { return false }
	}
	return true
}

collect_reference_candidates :: proc(
	inputs: [][]u8,
	max_candidates, window_size: int,
	allocator: mem.Allocator,
) -> [dynamic]Reference_Candidate {
	candidates := make([dynamic]Reference_Candidate, 0, min(max_candidates, 4096), allocator)
	table := make(map[Reference_Hash]Reference_Candidate, min(max_candidates, 4096), allocator)
	defer delete(table)

	total: u64
	possible: u64
	for input in inputs {
		length := len(input)
		if length >= window_size {
			possible += u64(length-window_size+1)
		}
		if total > ~u64(0)-u64(length) { return candidates }
		total += u64(length)
	}
	_ = total

	for input, input_index in inputs {
		if len(input) < window_size { continue }
		input_positions := len(input)-window_size+1
		budget := max(1, input_positions)
		if possible > 0 {
			share := (u64(max_candidates)*u64(input_positions))/possible
			budget = max(1, int(min(share, u64(input_positions))))
		}
		stride := max(1, input_positions/budget)
		for at := 0; at < input_positions; at += stride {
			key := reference_window_hash(input[at:at+window_size])
			existing, found := table[key]
			if found && same_candidate_bytes(inputs, existing, input[at:at+window_size]) {
				existing.count += 1
				if existing.last_input != input_index {
					existing.input_count += 1
					existing.last_input = input_index
				}
				table[key] = existing
				continue
			}
			if found || len(table) >= max_candidates { continue }
			table[key] = Reference_Candidate{
				input_index = input_index,
				at = at,
				length = window_size,
				count = 1,
				input_count = 1,
				last_input = input_index,
			}
		}
	}
	for _, candidate in table {
		append(&candidates, candidate)
	}
	return candidates
}

append_candidate_reference :: proc(
	result: ^[dynamic]u8,
	inputs: [][]u8,
	candidate: Reference_Candidate,
	maximum_size, maximum_segment: int,
) -> bool {
	if candidate.input_index < 0 || candidate.input_index >= len(inputs) ||
	   len(result) >= maximum_size {
		return false
	}
	input := inputs[candidate.input_index]
	if candidate.at < 0 || candidate.at > len(input) { return false }
	length := min(maximum_segment, len(input)-candidate.at)
	length = min(length, maximum_size-len(result))
	if length <= 0 { return false }
	segment := input[candidate.at:candidate.at+length]
	if !contains_chunk(result[:], segment) {
		append(result, ..segment)
		return true
	}
	return false
}

coverage_set_create :: proc(capacity: int, allocator: mem.Allocator) -> Coverage_Set {
	size := 1
	for size < max(2, capacity*2) {
		size *= 2
	}
	return Coverage_Set{
		keys = make([]Reference_Hash, size, allocator),
		occupied = make([]bool, size, allocator),
		allocator = allocator,
	}
}

coverage_set_destroy :: proc(set: ^Coverage_Set) {
	if set == nil { return }
	delete(set.keys, set.allocator)
	delete(set.occupied, set.allocator)
	set^ = {}
}

coverage_set_slot :: proc(set: ^Coverage_Set, key: Reference_Hash) -> int {
	if set == nil || len(set.keys) == 0 || (len(set.keys)&(len(set.keys)-1)) != 0 {
		return -1
	}
	slot := int(key.first & u64(len(set.keys)-1))
	start := slot
	for {
		if !set.occupied[slot] || set.keys[slot] == key { return slot }
		slot = (slot+1) & (len(set.keys)-1)
		if slot == start { return -1 }
	}
}

coverage_set_contains :: proc(set: ^Coverage_Set, key: Reference_Hash) -> bool {
	slot := coverage_set_slot(set, key)
	return slot >= 0 && set.occupied[slot]
}

coverage_set_insert :: proc(set: ^Coverage_Set, key: Reference_Hash) {
	slot := coverage_set_slot(set, key)
	if slot < 0 { return }
	set.keys[slot] = key
	set.occupied[slot] = true
}

candidate_has_new_coverage :: proc(
	inputs: [][]u8,
	candidate: Reference_Candidate,
	covered: ^Coverage_Set,
) -> bool {
	input := inputs[candidate.input_index]
	segment := input[candidate.at:candidate.at+candidate.length]
	gram_size := min(4, len(segment))
	for at in 0..=len(segment)-gram_size {
		key := reference_window_hash(segment[at:at+gram_size])
		if !coverage_set_contains(covered, key) { return true }
	}
	return false
}

mark_candidate_coverage :: proc(
	inputs: [][]u8,
	candidate: Reference_Candidate,
	covered: ^Coverage_Set,
) {
	input := inputs[candidate.input_index]
	segment := input[candidate.at:candidate.at+candidate.length]
	gram_size := min(4, len(segment))
	for at in 0..=len(segment)-gram_size {
		coverage_set_insert(covered, reference_window_hash(segment[at:at+gram_size]))
	}
}

build_representative_reference :: proc(
	inputs: [][]u8,
	maximum_size: int,
	chunk_size: int,
	allocator: mem.Allocator,
) -> []u8 {
	result := make([dynamic]u8, 0, min(maximum_size, 4096), allocator)
	if len(inputs) == 0 || maximum_size <= 0 { return result[:] }
	chunk_length := min(max(1, chunk_size), maximum_size)
	slots := maximum_size/chunk_length
	for slot in 0..<slots {
		input_index := slot%len(inputs)
		input := inputs[input_index]
		if len(input) == 0 { continue }
		round := slot/len(inputs)
		rounds := (slots+len(inputs)-1-input_index)/len(inputs)
		at := 0
		if rounds > 1 { at = round*(len(input)-min(chunk_length, len(input)))/(rounds-1) }
		count := min(chunk_length, len(input)-at, maximum_size-len(result))
		if count > 0 {
			chunk := input[at:at+count]
			if !contains_chunk(result[:], chunk) {
				append(&result, ..chunk)
			}
		}
		if len(result) >= maximum_size { break }
	}
	if len(result) < maximum_size {
		for input in inputs {
			remaining := maximum_size-len(result)
			if remaining <= 0 { break }
			count := min(len(input), remaining)
			if count > 0 && !contains_chunk(result[:], input[:count]) {
				append(&result, ..input[:count])
			}
		}
	}
	return result[:]
}

build_scored_reference :: proc(
	inputs: [][]u8,
	maximum_size: int,
	coverage: bool,
	allocator: mem.Allocator,
) -> []u8 {
	result := make([dynamic]u8, 0, min(maximum_size, 4096), allocator)
	if maximum_size <= 0 || len(inputs) == 0 { return result[:] }
	window_size := min(16, maximum_size)
	if coverage { window_size = min(12, maximum_size) }
	if window_size <= 0 { return result[:] }
	max_candidates := min(65_536, max(1024, maximum_size/2))
	candidates := collect_reference_candidates(inputs, max_candidates, window_size, allocator)
	defer delete(candidates)
	sort_reference_candidates(inputs, candidates, coverage)

	segment_limit := window_size
	covered: Coverage_Set
	if coverage {
		covered_capacity := len(candidates)*max(1, window_size-3)
		covered = coverage_set_create(covered_capacity, allocator)
		defer coverage_set_destroy(&covered)
	}
	for candidate in candidates {
		if coverage && !candidate_has_new_coverage(inputs, candidate, &covered) {
			continue
		}
		if append_candidate_reference(&result, inputs, candidate, maximum_size, segment_limit) &&
		   coverage {
			mark_candidate_coverage(inputs, candidate, &covered)
		}
		if len(result) >= maximum_size { break }
	}
	return result[:]
}

build_concatenated_reference :: proc(
	inputs: [][]u8,
	maximum_size: int,
	allocator: mem.Allocator,
) -> []u8 {
	result := make([dynamic]u8, 0, maximum_size, allocator)
	for input in inputs {
		remaining := maximum_size-len(result)
		if remaining <= 0 { break }
		append(&result, ..input[:min(len(input), remaining)])
	}
	return result[:]
}

checked_reference_size :: proc(inputs: [][]u8, maximum_size: int) -> (int, Error) {
	if maximum_size < 0 { return 0, .Invalid_Argument }
	if maximum_size > 0xffffffff { return 0, .Limit_Exceeded }
	total: u64
	for input in inputs {
		if u64(len(input)) > 0xffffffff { return 0, .Limit_Exceeded }
		if total > ~u64(0)-u64(len(input)) { return 0, .Limit_Exceeded }
		total += u64(len(input))
	}
	return maximum_size, .None
}

reference_score :: proc(
	inputs: [][]u8,
	reference: []u8,
	allocator: mem.Allocator,
) -> (u64, Error) {
	if err := validate_sizes(reference, nil); err != .None { return 0, err }
	index := index_create(reference, allocator)
	encoder := Encoder{reference = reference, index = index}
	defer encoder_destroy(&encoder)
	total := u64(len(reference))
	for format in Format.RLZ..=Format.RLZAP {
		encoder.options = default_options(format)
		for input in inputs {
			module, err := encode_format_indexed(&encoder, input, allocator)
			if err != .None { return 0, err }
			size, size_err := serialized_size(&module)
			module_destroy(&module)
			if size_err != .None { return 0, size_err }
			if total > ~u64(0)-u64(size) { return 0, .Limit_Exceeded }
			total += u64(size)
		}
	}
	return total, .None
}

// reference_build constructs an owned shared reference. The caller owns the
// returned buffer and must preserve it alongside every encoded module that uses
// it. Inputs and their contents are only borrowed during construction.
reference_build :: proc(
	inputs: [][]u8,
	options: Reference_Options = {},
	allocator: mem.Allocator = context.allocator,
) -> (reference: []u8, err: Error) {
	options := options
	if options.max_size == 0 { options.max_size = 1_048_576 }
	options.max_size, err = checked_reference_size(inputs, options.max_size)
	if err != .None { return nil, err }
	maximum_size := options.max_size

	switch options.strategy {
	case .Representative_Sampling:
		return build_representative_reference(inputs, maximum_size, 256, allocator), .None
	case .Frequent_Substrings:
		return build_scored_reference(inputs, maximum_size, false, allocator), .None
	case .Coverage_Optimized:
		return build_scored_reference(inputs, maximum_size, true, allocator), .None
	case .Automatic:
		refs := [4][]u8{
			build_representative_reference(inputs, maximum_size, 256, allocator),
			build_scored_reference(inputs, maximum_size, false, allocator),
			build_scored_reference(inputs, maximum_size, true, allocator),
			build_concatenated_reference(inputs, maximum_size, allocator),
		}
		defer {
			for built, i in refs {
				_ = i
				delete(built, allocator)
			}
		}

		best := -1
		best_score: u64 = ~u64(0)
		for candidate, candidate_index in refs {
			score, score_err := reference_score(inputs, candidate, allocator)
			if score_err != .None { return nil, score_err }
			if score < best_score || (score == best_score &&
			   (best < 0 || len(candidate) < len(refs[best]))) {
				best_score = score
				best = candidate_index
			}
		}
		empty_score, empty_err := reference_score(inputs, nil, allocator)
		if empty_err != .None { return nil, empty_err }
		if empty_score <= best_score { return nil, .None }

		owned := make([]u8, len(refs[best]), allocator)
		copy(owned, refs[best])
		return owned, .None
	}
	return nil, .Invalid_Argument
}

// encoder_create_from_inputs builds an owned reference and an encoder using it.
// Both values are caller-owned: destroy the encoder, then delete the reference.
encoder_create_from_inputs :: proc(
	inputs: [][]u8,
	reference_options: Reference_Options = {},
	encode_options: Encode_Options = DEFAULT_OPTIONS,
	allocator: mem.Allocator = context.allocator,
) -> (reference: []u8, encoder: Encoder, err: Error) {
	reference, err = reference_build(inputs, reference_options, allocator)
	if err != .None { return nil, {}, err }
	return reference, encoder_create(reference, encode_options, allocator), .None
}

// Compatibility wrapper around deterministic representative sampling.
build_reference :: proc(
	inputs: [][]u8,
	options: Reference_Builder_Options = {},
	allocator: mem.Allocator = context.allocator,
) -> []u8 {
	options := options
	maximum_size := options.maximum_size
	if maximum_size <= 0 { maximum_size = 1_048_576 }
	if options.chunk_size <= 0 { options.chunk_size = 256 }
	checked_size, err := checked_reference_size(inputs, maximum_size)
	reference: []u8
	if err != .None { return nil }
	reference = build_representative_reference(inputs, checked_size, options.chunk_size, allocator)
	return reference
}
