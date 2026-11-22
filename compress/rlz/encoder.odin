package rlz

import "core:mem"

RLZAP_Options :: struct {
    look_ahead:   int,
    delta_bits:   int,
    explicit_len: int,
    max_literals: int,
}

Encode_Options :: struct {
    format:   Format,
    minimum_reference_match: int,
    rlzap:    RLZAP_Options,
}

default_options :: proc(format: Format = .RLZ) -> Encode_Options {
    return Encode_Options{
        format = format,
        minimum_reference_match = 4,
        rlzap = RLZAP_Options{
            look_ahead = 16,
            delta_bits = 8,
            explicit_len = 4,
            max_literals = 255,
        },
    }
}

DEFAULT_OPTIONS :: Encode_Options{
    format = .RLZ,
    minimum_reference_match = 4,
    rlzap = RLZAP_Options{
        look_ahead = 16,
        delta_bits = 8,
        explicit_len = 4,
        max_literals = 255,
    },
}

Encoder :: struct {
    reference: []u8,
    index: Reference_Index,
    options: Encode_Options,
}

encoder_create :: proc(reference: []u8, options: Encode_Options = DEFAULT_OPTIONS, allocator: mem.Allocator = context.allocator) -> Encoder {
    options := options
    if options.minimum_reference_match <= 0 { options.minimum_reference_match = 4 }
    if options.rlzap.delta_bits <= 0 || options.rlzap.delta_bits >= 63 {
        options.rlzap.delta_bits = 8
    }
    if options.rlzap.explicit_len <= 0 { options.rlzap.explicit_len = 4 }
    if options.rlzap.max_literals <= 0 { options.rlzap.max_literals = 255 }
    if options.rlzap.look_ahead < 0 { options.rlzap.look_ahead = 0 }
    return Encoder{
        reference = reference,
        index = index_create(reference, allocator),
        options = options,
    }
}

encoder_destroy :: proc(encoder: ^Encoder) {
    if encoder == nil { return }
    index_destroy(&encoder.index)
    encoder^ = {}
}

encode_into :: proc(encoder: ^Encoder, input: []u8, target: ^Module, allocator: mem.Allocator = context.allocator) -> Error {
    if encoder == nil || target == nil { return .Invalid_Argument }
    m, err := encode_format_indexed(encoder, input, allocator)
    if err != .None { return err }
    module_destroy(target)
    target^ = m
    return .None
}

encode_indexed :: proc(encoder: ^Encoder, input: []u8, allocator: mem.Allocator = context.allocator) -> (Module, Error) {
    if encoder == nil { return {}, .Invalid_Argument }
    return encode_format_indexed(encoder, input, allocator)
}

encode_format :: proc(reference, input: []u8, format: Format, options: Encode_Options = DEFAULT_OPTIONS, allocator: mem.Allocator = context.allocator) -> (Module, Error) {
    options := options
    options.format = format
    encoder := encoder_create(reference, options, allocator)
    defer encoder_destroy(&encoder)
    return encode_format_indexed(&encoder, input, allocator)
}

encode_format_indexed :: proc(encoder: ^Encoder, input: []u8, allocator: mem.Allocator) -> (m: Module, err: Error) {
    opts := encoder.options
    m, err = new_module(encoder.reference, input, opts.format, allocator)
    if err != .None { return {}, err }
    pos := 0
    explicit_pointer := i64(0)
    have_explicit := false
    for pos < len(input) {
        source, length := longest_match(&encoder.index, input, pos)

        if opts.format == .RLZ {
            if length >= opts.minimum_reference_match {
                append_reference(&m, pos, source, length)
                pos += length
            } else {
                append_literal(&m, input, pos, 1)
                pos += 1
            }
            continue
        }

        if opts.format == .RLZAP && length >= opts.rlzap.explicit_len {
            displacement := i64(source)-i64(pos)
            adaptive := false
            if have_explicit {
                delta := displacement-explicit_pointer
                limit := i64(1) << u64(opts.rlzap.delta_bits-1)
                adaptive = delta >= -limit && delta < limit
            }
            if adaptive || !have_explicit {
                // A small lookahead can postpone an expensive literal-free boundary.
                if opts.rlzap.look_ahead > 0 && pos+1 < len(input) {
                    next_source, next_length := longest_match(&encoder.index, input, pos+1)
                    if next_length > length+opts.rlzap.look_ahead &&
                       next_length >= opts.minimum_reference_match {
                        append_literal(&m, input, pos, 1)
                        pos += 1
                        continue
                    }
                    _ = next_source
                }
                append_reference(&m, pos, source, length, adaptive)
                if !adaptive { explicit_pointer, have_explicit = displacement, true }
                pos += length
                continue
            }
        }

        // GDC, relative GDC and explicit RLZAP all use the same greedy copy
        // followed by the target mismatch byte. Only representation differs.
        if length >= opts.minimum_reference_match {
            append_reference(&m, pos, source, length)
            if opts.format == .RLZAP {
                explicit_pointer = i64(source)-i64(pos)
                have_explicit = true
            }
            pos += length
            if pos < len(input) {
                append_literal(&m, input, pos, 1)
                pos += 1
            }
        } else {
            literal_count := 1
            limit := len(input)-pos
            if opts.format == .RLZAP && opts.rlzap.max_literals < limit {
                limit = opts.rlzap.max_literals
            }
            for literal_count < limit {
                _, next_length := longest_match(&encoder.index, input, pos+literal_count)
                if next_length >= opts.minimum_reference_match { break }
                literal_count += 1
            }
            append_literal(&m, input, pos, literal_count)
            pos += literal_count
        }
    }
    return m, .None
}
