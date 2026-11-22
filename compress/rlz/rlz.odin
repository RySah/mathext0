package rlz

import intrinsics "base:intrinsics"
import "core:mem"
import "core:simd"

// Standalone binary relative-Lempel-Ziv codec. A Module owns its phrase and
// literal arrays; references are borrowed and must remain unchanged.

Format :: enum u8 {
    RLZ          = 0,
    GDC          = 1,
    GDC_Relative = 2,
    RLZAP        = 3,
}

Backend :: enum u8 {
    CPU,
    GPU, // Backwards-compatible name for a caller-provided GPU callback.
    Vulkan,
    OpenGL,
    Auto,
}

Phrase_Kind :: enum u32 {
    Reference          = 0,
    Literal            = 1,
    Reference_Adaptive = 2,
}

// Exactly 16 bytes, preserving the existing Vulkan phrase ABI.
Phrase :: struct {
    output_offset: u32,
    source_offset: u32,
    length:        u32,
    kind:          Phrase_Kind,
}

Module :: struct {
    phrases:     [dynamic]Phrase,
    literals:    [dynamic]u8,
    output_size: u32,
    format:      Format,
    reference_id: u64,
}

Error :: enum {
    None,
    Invalid_Argument,
    Invalid_Stream,
    Output_Too_Small,
    Unsupported_Version,
    Unsupported_Backend,
    Backend_Failed,
    Limit_Exceeded,
    Truncated,
    Reference_Mismatch,
}

GPU_Decode_Proc :: proc "odin" (
    user_data: rawptr,
    reference: []u8,
    module: ^Module,
    output: []u8,
) -> Error

Decoder :: struct {
    backend: Backend,
    gpu_proc: GPU_Decode_Proc,
    gpu_user_data: rawptr,
    maximum_output: u64,
    bound_reference_id: u64,
}

cpu_decoder :: proc(maximum_output: u64 = 0) -> Decoder {
    return Decoder{backend = .CPU, maximum_output = maximum_output}
}

decoder_create :: proc(reference: []u8, backend: Backend = .CPU, maximum_output: u64 = 0) -> Decoder {
    return Decoder{
        backend = backend,
        maximum_output = maximum_output,
        bound_reference_id = reference_id(reference),
    }
}

decoder_destroy :: proc(decoder: ^Decoder) {
    if decoder == nil { return }
    decoder^ = {}
}

gpu_decoder :: proc(callback: GPU_Decode_Proc, user_data: rawptr = nil) -> Decoder {
    return Decoder{backend = .GPU, gpu_proc = callback, gpu_user_data = user_data}
}

module_destroy :: proc(m: ^Module) {
    if m == nil { return }
    delete(m.phrases)
    delete(m.literals)
    m^ = {}
}

reference_id :: proc(reference: []u8) -> u64 {
    // FNV-1a64 includes length to distinguish a prefix from an equal hash stream.
    hash := u64(0xcbf29ce484222325)
    hash = hash ~ u64(len(reference))
    hash *= 0x100000001b3
    for byte in reference {
        hash = hash ~ u64(byte)
        hash *= 0x100000001b3
    }
    return hash
}

append_literal :: proc(m: ^Module, input: []u8, pos: int, count: int) {
    literal_at := len(m.literals)
    append(&m.literals, ..input[pos:pos+count])
    if len(m.phrases) > 0 {
        last := &m.phrases[len(m.phrases)-1]
        if last.kind == .Literal &&
           u64(last.output_offset)+u64(last.length) == u64(pos) &&
           u64(last.source_offset)+u64(last.length) == u64(literal_at) {
            last.length += u32(count)
            return
        }
    }
    append(&m.phrases, Phrase{
        output_offset = u32(pos),
        source_offset = u32(literal_at),
        length        = u32(count),
        kind          = .Literal,
    })
}

append_reference :: proc(m: ^Module, output_at, source_at, count: int, adaptive := false) {
    kind := Phrase_Kind.Reference
    if adaptive { kind = .Reference_Adaptive }
    append(&m.phrases, Phrase{
        output_offset = u32(output_at),
        source_offset = u32(source_at),
        length        = u32(count),
        kind          = kind,
    })
}

validate_sizes :: proc(reference, input: []u8, maximum_output: u64 = 0) -> Error {
    if u64(len(input)) > 0xffffffff || u64(len(reference)) > 0xffffffff {
        return .Invalid_Argument
    }
    if maximum_output != 0 && u64(len(input)) > maximum_output {
        return .Limit_Exceeded
    }
    return .None
}

new_module :: proc(reference, input: []u8, format: Format, allocator: mem.Allocator) -> (m: Module, err: Error) {
    err = validate_sizes(reference, input)
    if err != .None { return {}, err }
    m.phrases = make([dynamic]Phrase, 0, 0, allocator)
    m.literals = make([dynamic]u8, 0, 0, allocator)
    m.output_size = u32(len(input))
    m.format = format
    m.reference_id = reference_id(reference)
    return m, .None
}

encode :: proc(reference, input: []u8, allocator: mem.Allocator = context.allocator) -> (Module, Error) {
    return encode_format(reference, input, .RLZ, {}, allocator)
}

validate :: proc(reference: []u8, m: ^Module) -> bool {
    if m == nil { return false }
    if m.reference_id != 0 && m.reference_id != reference_id(reference) { return false }
    at: u64 = 0
    total := u64(m.output_size)
    for p in m.phrases {
        if p.length == 0 || u64(p.output_offset) != at { return false }
        if at > total || u64(p.length) > total-at { return false }
        source_len: u64
        switch p.kind {
        case .Reference, .Reference_Adaptive:
            source_len = u64(len(reference))
        case .Literal:
            source_len = u64(len(m.literals))
        case:
            return false
        }
        if u64(p.source_offset) > source_len ||
           u64(p.length) > source_len-u64(p.source_offset) {
            return false
        }
        at += u64(p.length)
    }
    return at == total
}

// Finds the phrase containing position, or the first phrase after it.
phrase_at :: proc(m: ^Module, position: u32) -> (int, bool) {
    if m == nil || len(m.phrases) == 0 || position >= m.output_size {
        return 0, false
    }
    lo, hi := 0, len(m.phrases)
    for lo < hi {
        mid := lo + (hi-lo)/2
        if m.phrases[mid].output_offset <= position { lo = mid+1 }
        else { hi = mid }
    }
    return lo-1, true
}

decode_cpu :: proc(reference: []u8, m: ^Module, output: []u8) -> Error {
    if m == nil { return .Invalid_Argument }
    if len(output) < int(m.output_size) { return .Output_Too_Small }
    if !validate(reference, m) { return invalid_reference_error(reference, m) }
    return decode_cpu_unchecked(reference, m, output)
}

decode_cpu_scalar :: proc(reference: []u8, m: ^Module, output: []u8) -> Error {
    if m == nil { return .Invalid_Argument }
    if len(output) < int(m.output_size) { return .Output_Too_Small }
    if !validate(reference, m) { return invalid_reference_error(reference, m) }
    return decode_cpu_unchecked_mode(reference, m, output, false)
}

decode_cpu_simd :: proc(reference: []u8, m: ^Module, output: []u8) -> Error {
    if m == nil { return .Invalid_Argument }
    if len(output) < int(m.output_size) { return .Output_Too_Small }
    if !validate(reference, m) { return invalid_reference_error(reference, m) }
    return decode_cpu_unchecked_mode(reference, m, output, true)
}

decode_into :: proc(decoder: ^Decoder, reference: []u8, m: ^Module, output: []u8) -> Error {
    return decode(decoder, reference, m, output)
}

decode_range_cpu :: proc(reference: []u8, m: ^Module, start, length: u32, output: []u8) -> Error {
    if m == nil { return .Invalid_Argument }
    if u64(start)+u64(length) > u64(m.output_size) { return .Invalid_Argument }
    if u64(len(output)) < u64(length) { return .Output_Too_Small }
    if !validate(reference, m) { return invalid_reference_error(reference, m) }
    if length == 0 { return .None }

    index, ok := phrase_at(m, start)
    if !ok { return .Invalid_Stream }
    at := start
    end := start+length
    for index < len(m.phrases) && at < end {
        p := m.phrases[index]
        delta := at-p.output_offset
        count := p.length-delta
        if at+count > end { count = end-at }
        from := int(p.source_offset+delta)
        into := int(at-start)
        switch p.kind {
        case .Reference, .Reference_Adaptive:
            copy(output[into:into+int(count)], reference[from:from+int(count)])
        case .Literal:
            copy(output[into:into+int(count)], m.literals[from:from+int(count)])
        case:
            return .Invalid_Stream
        }
        at += count
        index += 1
    }
    if at != end { return .Invalid_Stream }
    return .None
}

copy_decode_bytes :: proc(dst, src: []u8, simd_enabled: bool) {
    at := 0
    when simd.HAS_HARDWARE_SIMD {
        if simd_enabled {
            Vector :: #simd[16]u8
            for len(src)-at >= 16 {
                value0 := intrinsics.unaligned_load((^Vector)(&src[at]))
                intrinsics.unaligned_store((^Vector)(&dst[at]), value0)
                at += 16
            }
        }
    }
    if at < len(src) { copy(dst[at:], src[at:]) }
}

decode_cpu_unchecked :: proc(reference: []u8, m: ^Module, output: []u8) -> Error {
    return decode_cpu_unchecked_mode(reference, m, output, false)
}

decode_cpu_unchecked_mode :: proc(reference: []u8, m: ^Module, output: []u8, simd_enabled: bool) -> Error {
    output_size := int(m.output_size)
    for p in m.phrases {
        from := int(p.source_offset)
        count := int(p.length)
        into := int(p.output_offset)
        if p.kind == .Literal {
            copy_decode_bytes(output[into:into+count], m.literals[from:from+count], simd_enabled)
        } else {
            copy_decode_bytes(output[into:into+count], reference[from:from+count], simd_enabled)
        }
    }
    _ = output_size
    return .None
}

invalid_reference_error :: proc(reference: []u8, m: ^Module) -> Error {
    if m.reference_id != 0 && m.reference_id != reference_id(reference) {
        return .Reference_Mismatch
    }
    return .Invalid_Stream
}

decode_range :: proc(decoder: ^Decoder, reference: []u8, m: ^Module, start, length: u32, output: []u8) -> Error {
    if decoder == nil || m == nil { return .Invalid_Argument }
    if u64(start)+u64(length) > u64(m.output_size) { return .Invalid_Argument }
    if u64(len(output)) < u64(length) { return .Output_Too_Small }
    if decoder.maximum_output != 0 && u64(length) > decoder.maximum_output {
        return .Limit_Exceeded
    }
    if decoder.backend != .CPU && decoder.backend != .Auto {
        if length != m.output_size || start != 0 { return .Unsupported_Backend }
        return decode(decoder, reference, m, output)
    }
    return decode_range_cpu(reference, m, start, length, output)
}

decode :: proc(decoder: ^Decoder, reference: []u8, m: ^Module, output: []u8) -> Error {
    if decoder == nil || m == nil { return .Invalid_Argument }
    if len(output) < int(m.output_size) { return .Output_Too_Small }
    if decoder.maximum_output != 0 && u64(m.output_size) > decoder.maximum_output {
        return .Limit_Exceeded
    }
    if decoder.bound_reference_id != 0 && decoder.bound_reference_id != reference_id(reference) {
        return .Reference_Mismatch
    }
    if decoder.bound_reference_id == 0 {
        if !validate(reference, m) { return invalid_reference_error(reference, m) }
    } else if decoder.bound_reference_id != m.reference_id && m.reference_id != 0 {
        return .Reference_Mismatch
    } else if !validate_without_reference(m, reference) {
        return .Invalid_Stream
    }
    switch decoder.backend {
    case .CPU, .Auto:
        return decode_cpu_unchecked(reference, m, output)
    case .GPU, .Vulkan, .OpenGL:
        if decoder.gpu_proc == nil { return .Unsupported_Backend }
        return decoder.gpu_proc(decoder.gpu_user_data, reference, m, output)
    }

    return .Unsupported_Backend
}

validate_without_reference :: proc(m: ^Module, reference: []u8) -> bool {
    if m == nil { return false }
    at: u64 = 0
    for p in m.phrases {
        if p.length == 0 || u64(p.output_offset) != at ||
           at > u64(m.output_size) || u64(p.length) > u64(m.output_size)-at {
            return false
        }
        source_len: u64
        switch p.kind {
        case .Reference, .Reference_Adaptive: source_len = u64(len(reference))
        case .Literal: source_len = u64(len(m.literals))
        case: return false
        }
        if u64(p.source_offset) > source_len ||
           u64(p.length) > source_len-u64(p.source_offset) {
            return false
        }
        at += u64(p.length)
    }
    return at == u64(m.output_size)
}

decoded_size :: proc(m: ^Module) -> (int, Error) {
    if m == nil { return 0, .Invalid_Argument }
    return int(m.output_size), .None
}

pack_bytes :: proc(src: []u8, allocator: mem.Allocator = context.allocator) -> []u32 {
    words := len(src)/4
    if len(src)%4 != 0 { words += 1 }
    out := make([]u32, words, allocator)
    for i in 0..<len(src) {
        out[i/4] |= u32(src[i]) << u32((i%4)*8)
    }
    return out
}
