package rlz

import "core:mem"

SERIAL_VERSION :: u8(1)
SERIAL_MAGIC :: [4]u8{'R', 'L', 'Z', '1'}

uleb_size :: proc(value: u64) -> int {
    value := value
    n := 1
    for value >= 128 {
        value >>= 7
        n += 1
    }
    return n
}

append_uleb :: proc(output: ^[dynamic]u8, value: u64) {
    value := value
    for {
        byte := u8(value & 0x7f)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        append(output, byte)
        if value == 0 { break }
    }
}

read_uleb :: proc(data: []u8, cursor: ^int) -> (u64, Error) {
    if cursor == nil { return 0, .Invalid_Argument }
    value: u64 = 0
    shift: u64 = 0
    for count in 0..<10 {
        if cursor^ >= len(data) { return 0, .Truncated }
        byte := data[cursor^]
        cursor^ += 1
        payload := u64(byte & 0x7f)
        if shift >= 64 || (shift == 63 && payload > 1) {
            return 0, .Invalid_Stream
        }
        value |= payload << shift
        if byte & 0x80 == 0 {
            if count == 9 && payload > 1 { return 0, .Invalid_Stream }
            return value, .None
        }
        shift += 7
    }
    return 0, .Invalid_Stream
}

zigzag :: proc(value: i64) -> u64 {
    return u64(value << 1) ~ u64(value >> 63)
}

unzigzag :: proc(value: u64) -> i64 {
    return i64(value >> 1) ~ -i64(value & 1)
}

checked_add_i64 :: proc(a, b: i64) -> (i64, bool) {
    MAX_I64 :: 0x7fff_ffff_ffff_ffff
    MIN_I64 :: -0x7fff_ffff_ffff_ffff-1
    if (b > 0 && a > MAX_I64-b) || (b < 0 && a < MIN_I64-b) {
        return 0, false
    }
    return a+b, true
}

serialized_size :: proc(m: ^Module) -> (int, Error) {
    if m == nil { return 0, .Invalid_Argument }
    size := 4+1+1+8
    size += uleb_size(u64(m.output_size))
    size += uleb_size(u64(len(m.phrases)))
    size += uleb_size(u64(len(m.literals)))
    explicit: i64 = 0
    have_explicit := false
    for p, index in m.phrases {
        _ = index
        size += 1+uleb_size(u64(p.length))
        switch p.kind {
        case .Literal:
            size += uleb_size(u64(p.source_offset))
        case .Reference:
            if m.format == .RLZ || m.format == .GDC {
                size += uleb_size(u64(p.source_offset))
            } else {
                displacement := i64(p.source_offset)-i64(p.output_offset)
                if !(m.format == .GDC_Relative && have_explicit && displacement == explicit) {
                    size += uleb_size(zigzag(displacement))
                }
                explicit = displacement
                have_explicit = true
            }
        case .Reference_Adaptive:
            if m.format != .RLZAP { return 0, .Invalid_Stream }
            displacement := i64(p.source_offset)-i64(p.output_offset)
            size += uleb_size(zigzag(displacement-explicit))
        case:
            return 0, .Invalid_Stream
        }
    }
    return size+len(m.literals), .None
}

serialize_into :: proc(m: ^Module, output: []u8) -> (int, Error) {
    if m == nil { return 0, .Invalid_Argument }
    if len(m.phrases) > 0 {
        // Serialization validation needs a reference for source bounds. Structural
        // consistency is still checked here; callers validate before publication.
        at: u64 = 0
        for p in m.phrases {
            if p.length == 0 || u64(p.output_offset) != at ||
               at > u64(m.output_size) || u64(p.length) > u64(m.output_size)-at {
                return 0, .Invalid_Stream
            }
            at += u64(p.length)
        }
        if at != u64(m.output_size) { return 0, .Invalid_Stream }
    } else if m.output_size != 0 {
        return 0, .Invalid_Stream
    }
    required, err := serialized_size(m)
    if err != .None { return 0, err }
    if len(output) < required { return required, .Output_Too_Small }

    cursor := 0
    for b in SERIAL_MAGIC { output[cursor] = b; cursor += 1 }
    output[cursor] = SERIAL_VERSION; cursor += 1
    output[cursor] = u8(m.format); cursor += 1
    for shift := 0; shift < 64; shift += 8 {
        output[cursor] = u8(m.reference_id >> u64(shift)); cursor += 1
    }

    buffer := make([dynamic]u8, 0, 32, context.temp_allocator)
    append_value :: proc(output: []u8, cursor: ^int, buffer: ^[dynamic]u8, value: u64) {
        clear(buffer)
        append_uleb(buffer, value)
        copy(output[cursor^:cursor^+len(buffer)], buffer[:])
        cursor^ += len(buffer)
    }
    append_value(output, &cursor, &buffer, u64(m.output_size))
    append_value(output, &cursor, &buffer, u64(len(m.phrases)))
    append_value(output, &cursor, &buffer, u64(len(m.literals)))

    explicit: i64 = 0
    have_explicit := false
    for p in m.phrases {
        tag := u8(p.kind)
        displacement := i64(p.source_offset)-i64(p.output_offset)
        repeated := m.format == .GDC_Relative && p.kind == .Reference &&
            have_explicit && displacement == explicit
        if repeated { tag |= 0x80 }
        output[cursor] = tag; cursor += 1
        switch p.kind {
        case .Literal:
            append_value(output, &cursor, &buffer, u64(p.source_offset))
        case .Reference:
            if m.format == .RLZ || m.format == .GDC {
                append_value(output, &cursor, &buffer, u64(p.source_offset))
            } else {
                if !repeated {
                    append_value(output, &cursor, &buffer, zigzag(displacement))
                }
                explicit = displacement
                have_explicit = true
            }
        case .Reference_Adaptive:
            if m.format != .RLZAP { return 0, .Invalid_Stream }
            append_value(output, &cursor, &buffer, zigzag(displacement-explicit))
        }
        append_value(output, &cursor, &buffer, u64(p.length))
    }
    copy(output[cursor:cursor+len(m.literals)], m.literals[:])
    cursor += len(m.literals)
    return cursor, .None
}

serialize :: proc(m: ^Module, allocator: mem.Allocator = context.allocator) -> ([]u8, Error) {
    size, err := serialized_size(m)
    if err != .None { return nil, err }
    output := make([]u8, size, allocator)
    written, err2 := serialize_into(m, output)
    if err2 != .None {
        delete(output, allocator)
        return nil, err2
    }
    return output[:written], .None
}

Deserialize_Options :: struct {
    maximum_output: u64,
    maximum_phrases: u64,
    maximum_literals: u64,
}

deserialize :: proc(data, reference: []u8, options: Deserialize_Options = {}, allocator: mem.Allocator = context.allocator) -> (m: Module, err: Error) {
    options := options
    if options.maximum_output == 0 { options.maximum_output = 4*u64(0x40000000) }
    if options.maximum_phrases == 0 { options.maximum_phrases = 16_000_000 }
    if options.maximum_literals == 0 { options.maximum_literals = options.maximum_output }
    if len(data) < 14 { return {}, .Truncated }
    for b, i in SERIAL_MAGIC {
        if data[i] != b { return {}, .Invalid_Stream }
    }
    if data[4] != SERIAL_VERSION { return {}, .Unsupported_Version }
    if data[5] > u8(Format.RLZAP) { return {}, .Invalid_Stream }
    m.format = Format(data[5])
    for shift := 0; shift < 64; shift += 8 {
        m.reference_id |= u64(data[6+shift/8]) << u64(shift)
    }
    if m.reference_id != reference_id(reference) { return {}, .Reference_Mismatch }

    cursor := 14
    output_size, read_err := read_uleb(data, &cursor)
    if read_err != .None { return {}, read_err }
    phrase_count, read_err2 := read_uleb(data, &cursor)
    if read_err2 != .None { return {}, read_err2 }
    literal_count, read_err3 := read_uleb(data, &cursor)
    if read_err3 != .None { return {}, read_err3 }
    if output_size > 0xffffffff || output_size > options.maximum_output ||
       phrase_count > options.maximum_phrases ||
       literal_count > options.maximum_literals {
        return {}, .Limit_Exceeded
    }
    m.output_size = u32(output_size)
    m.phrases = make([dynamic]Phrase, 0, int(phrase_count), allocator)
    m.literals = make([dynamic]u8, int(literal_count), int(literal_count), allocator)

    output_at: u64 = 0
    explicit: i64 = 0
    have_explicit := false
    for _ in 0..<int(phrase_count) {
        if cursor >= len(data) { module_destroy(&m); return {}, .Truncated }
        raw_kind := data[cursor]; cursor += 1
        repeated := raw_kind & 0x80 != 0
        kind := Phrase_Kind(raw_kind & 0x7f)
        if kind > .Reference_Adaptive ||
           (repeated && (m.format != .GDC_Relative || kind != .Reference || !have_explicit)) {
            module_destroy(&m); return {}, .Invalid_Stream
        }
        encoded_pointer: u64
        pointer_err: Error = .None
        source_at: u64
        if repeated {
            encoded_pointer = 0
        } else {
            encoded_pointer, pointer_err = read_uleb(data, &cursor)
        }
        if pointer_err != .None { module_destroy(&m); return {}, pointer_err }
        switch kind {
        case .Literal:
            source_at = encoded_pointer
        case .Reference:
            if m.format == .RLZ || m.format == .GDC {
                source_at = encoded_pointer
            } else {
                if !repeated {
                    explicit = unzigzag(encoded_pointer)
                    have_explicit = true
                }
                resolved, ok := checked_add_i64(i64(output_at), explicit)
                if !ok { module_destroy(&m); return {}, .Invalid_Stream }
                if resolved < 0 { module_destroy(&m); return {}, .Invalid_Stream }
                source_at = u64(resolved)
            }
        case .Reference_Adaptive:
            if m.format != .RLZAP || !have_explicit {
                module_destroy(&m); return {}, .Invalid_Stream
            }
            displacement, ok := checked_add_i64(explicit, unzigzag(encoded_pointer))
            if !ok { module_destroy(&m); return {}, .Invalid_Stream }
            resolved, resolved_ok := checked_add_i64(i64(output_at), displacement)
            if !resolved_ok { module_destroy(&m); return {}, .Invalid_Stream }
            if resolved < 0 { module_destroy(&m); return {}, .Invalid_Stream }
            source_at = u64(resolved)
        }
        length, length_err := read_uleb(data, &cursor)
        if length_err != .None { module_destroy(&m); return {}, length_err }
        if length == 0 || length > output_size-output_at || source_at > 0xffffffff {
            module_destroy(&m); return {}, .Invalid_Stream
        }
        append(&m.phrases, Phrase{
            output_offset = u32(output_at),
            source_offset = u32(source_at),
            length        = u32(length),
            kind          = kind,
        })
        output_at += length
    }
    if output_at != output_size || cursor+int(literal_count) != len(data) {
        module_destroy(&m)
        return {}, .Invalid_Stream
    }
    copy(m.literals[:], data[cursor:])
    if !validate(reference, &m) {
        validation_err := invalid_reference_error(reference, &m)
        module_destroy(&m)
        return {}, validation_err
    }
    return m, .None
}
