package rlz

import "core:mem"
import "core:testing"

expect_bytes_equal :: proc(t: ^testing.T, got, want: []u8, message := "bytes differ") {
    testing.expect(t, len(got) == len(want), message)
    if len(got) != len(want) { return }
    for i in 0..<len(got) {
        if got[i] != want[i] {
            testing.expect(t, false, message)
            return
        }
    }
}

round_trip :: proc(t: ^testing.T, format: Format, reference, input: []u8) {
    module, err := encode_format(reference, input, format)
    defer module_destroy(&module)
    testing.expect_value(t, err, Error.None)
    if err != .None { return }

    output := make([]u8, len(input)+8)
    defer delete(output)
    decoder := cpu_decoder()
    err = decode(&decoder, reference, &module, output)
    testing.expect_value(t, err, Error.None)
    expect_bytes_equal(t, output[:len(input)], input)

    serialized, serial_err := serialize(&module)
    defer delete(serialized)
    testing.expect_value(t, serial_err, Error.None)
    if serial_err != .None { return }
    restored, restore_err := deserialize(serialized, reference)
    defer module_destroy(&restored)
    testing.expect_value(t, restore_err, Error.None)
    if restore_err != .None { return }
    testing.expect(t, restored.format == format)
    err = decode(&decoder, reference, &restored, output)
    testing.expect_value(t, err, Error.None)
    expect_bytes_equal(t, output[:len(input)], input)
}

@(test)
test_all_formats_edge_cases :: proc(t: ^testing.T) {
    reference := []u8{'a','b','c','d','e','f','g','h','i','j'}
    cases := [][ ]u8{
        {},
        {'a'},
        reference,
        {'x','y','z'},
        {'a','b','c','X','e','f','g'},
        {'a','b','c','d','I','N','S','E','R','T','e','f','g','h'},
    }
    for format in Format.RLZ..=Format.RLZAP {
        for input in cases {
            round_trip(t, format, reference, input)
        }
        round_trip(t, format, {}, {'b','i','n','a','r','y',0,255})
    }
}

@(test)
test_all_binary_bytes_and_repeated_patterns :: proc(t: ^testing.T) {
    reference := make([]u8, 512)
    defer delete(reference)
    input := make([]u8, 768)
    defer delete(input)
    for i in 0..<256 {
        reference[i] = u8(i)
        input[i] = u8(255-i)
    }
    for i in 256..<512 { reference[i] = u8(i&7) }
    for i in 256..<len(input) { input[i] = u8((i*17+3)&255) }
    for format in Format.RLZ..=Format.RLZAP {
        round_trip(t, format, reference, input)
    }
}

@(test)
test_random_round_trips :: proc(t: ^testing.T) {
    reference := make([]u8, 4096)
    defer delete(reference)
    state: u32 = 0x12345678
    for i in 0..<len(reference) {
        state = state*1664525+1013904223
        reference[i] = u8(state >> 24)
    }
    input := make([]u8, 2048)
    defer delete(input)
    for i in 0..<len(input) {
        if i < len(reference)/2 {
            input[i] = reference[i+997]
        } else {
            state = state*1664525+1013904223
            input[i] = u8(state >> 24)
        }
    }
    for format in Format.RLZ..=Format.RLZAP {
        round_trip(t, format, reference, input)
    }
}

@(test)
test_range_decoding_boundaries :: proc(t: ^testing.T) {
    reference := []u8{1,2,3,4,5,6,7,8,9,10}
    input := []u8{1,2,3,4,99,98,7,8,9,10,1,2,3,4}
    module, err := encode_format(reference, input, .RLZAP)
    defer module_destroy(&module)
    testing.expect_value(t, err, Error.None)
    decoder := cpu_decoder()
    ranges := [][2]u32{{0,0},{0,1},{2,7},{4,5},{9,3},{6,8}}
    for range in ranges {
        got := make([]u8, int(range[1]))
        decode_err := decode_range(&decoder, reference, &module, range[0], range[1], got)
        testing.expect_value(t, decode_err, Error.None)
        expect_bytes_equal(t, got, input[int(range[0]):int(range[0]+range[1])])
        delete(got)
    }
}

@(test)
test_reusable_encoder_and_index :: proc(t: ^testing.T) {
    reference := []u8{'0','1','2','3','4','5','6','7'}
    encoder := encoder_create(reference)
    defer encoder_destroy(&encoder)
    decoder := cpu_decoder()
    inputs := [][]u8{{'0','1','2','3','x'}, {'4','5','6','7'}, {}}
    for input in inputs {
        module, err := encode_indexed(&encoder, input)
        defer module_destroy(&module)
        testing.expect_value(t, err, Error.None)
        output := make([]u8, len(input))
        testing.expect_value(t, decode(&decoder, reference, &module, output), Error.None)
        expect_bytes_equal(t, output, input)
        delete(output)
    }
}

@(test)
test_validation_and_malformed_streams :: proc(t: ^testing.T) {
    reference := []u8{'a','b','c'}
    module, err := encode(reference, []u8{'a','b'})
    defer module_destroy(&module)
    testing.expect_value(t, err, Error.None)

    output := make([]u8, 2)
    defer delete(output)
    bad_ref := []u8{'x','b','c'}
    decoder := cpu_decoder()
    testing.expect_value(t, decode(&decoder, bad_ref, &module, output), Error.Reference_Mismatch)

    module.phrases[0].source_offset = 999
    testing.expect_value(t, decode_cpu(reference, &module, output), Error.Invalid_Stream)
    module.phrases[0].source_offset = 0

    serialized, serial_err := serialize(&module)
    defer delete(serialized)
    testing.expect_value(t, serial_err, Error.None)
    truncated, trunc_err := deserialize(serialized[:len(serialized)-1], reference)
    testing.expect_value(t, trunc_err, Error.Invalid_Stream)
    if trunc_err == .None { module_destroy(&truncated) }

    corrupted := make([]u8, len(serialized))
    defer delete(corrupted)
    copy(corrupted, serialized)
    corrupted[4] = 99
    wrong_version, version_err := deserialize(corrupted, reference)
    testing.expect_value(t, version_err, Error.Unsupported_Version)
    if version_err == .None { module_destroy(&wrong_version) }

    _, limited_err := deserialize(serialized, reference, Deserialize_Options{maximum_output = 1})
    testing.expect_value(t, limited_err, Error.Limit_Exceeded)
}

@(test)
test_deterministic_reference_builder :: proc(t: ^testing.T) {
    inputs := [][]u8{
        {'a','b','c','a','b','c'},
        {'a','b','c','d','e','f'},
    }
    a := build_reference(inputs, Reference_Builder_Options{maximum_size = 5, chunk_size = 3})
    defer delete(a)
    b := build_reference(inputs, Reference_Builder_Options{maximum_size = 5, chunk_size = 3})
    defer delete(b)
    expect_bytes_equal(t, a, b, "reference building must be deterministic")
    testing.expect(t, len(a) <= 5, "reference limit must be respected")
}

@(test)
test_generated_references_round_trip_every_format :: proc(t: ^testing.T) {
    inputs := [][]u8{
        {'a','b','c','d','e','f','g','h','a','b','c','d'},
        {'x','y','z','a','b','c','d','Q','R','S'},
        {'x','y','z','a','b','c','d','Q','R','S'},
        {},
        {0,1,2,3,0,1,2,3,255},
    }
    for strategy in Reference_Strategy.Automatic..=Reference_Strategy.Coverage_Optimized {
        reference, err := reference_build(inputs, Reference_Options{
            max_size = 19,
            strategy = strategy,
        })
        testing.expect_value(t, err, Error.None)
        testing.expect(t, len(reference) <= 19, "generated reference exceeds limit")
        for format in Format.RLZ..=Format.RLZAP {
            encoder := encoder_create(reference, default_options(format))
            for input in inputs {
                module, encode_err := encode_indexed(&encoder, input)
                testing.expect_value(t, encode_err, Error.None)
                output := make([]u8, len(input))
                decoder := cpu_decoder()
                testing.expect_value(t, decode(&decoder, reference, &module, output), Error.None)
                expect_bytes_equal(t, output, input)
                delete(output)
                module_destroy(&module)
            }
            encoder_destroy(&encoder)
        }
        delete(reference)
    }
}

@(test)
test_reference_build_options_and_convenience_encoder :: proc(t: ^testing.T) {
    inputs := [][]u8{
        {'A','A','A','A','B','B','B','B'},
        {'A','A','A','A','C','C','C','C'},
    }
    for strategy in Reference_Strategy.Representative_Sampling..=Reference_Strategy.Coverage_Optimized {
        first, first_err := reference_build(inputs, Reference_Options{max_size = 7, strategy = strategy})
        defer delete(first)
        second, second_err := reference_build(inputs, Reference_Options{max_size = 7, strategy = strategy})
        defer delete(second)
        testing.expect_value(t, first_err, Error.None)
        testing.expect_value(t, second_err, Error.None)
        testing.expect(t, len(first) <= 7)
        expect_bytes_equal(t, first, second, "reference strategy must be deterministic")
    }

    empty, empty_err := reference_build(nil, Reference_Options{max_size = 8})
    testing.expect_value(t, empty_err, Error.None)
    testing.expect(t, len(empty) == 0)
    delete(empty)
    _, invalid_err := reference_build(inputs, Reference_Options{max_size = -1})
    testing.expect_value(t, invalid_err, Error.Invalid_Argument)

    automatic, automatic_err := reference_build(inputs, Reference_Options{
        max_size = 8,
        strategy = .Automatic,
    })
    defer delete(automatic)
    testing.expect_value(t, automatic_err, Error.None)
    automatic_score, score_err := reference_score(inputs, automatic, context.allocator)
    testing.expect_value(t, score_err, Error.None)
    representative := build_representative_reference(inputs, 8, 256, context.allocator)
    defer delete(representative)
    concatenated := build_concatenated_reference(inputs, 8, context.allocator)
    defer delete(concatenated)
    representative_score, _ := reference_score(inputs, representative, context.allocator)
    concatenated_score, _ := reference_score(inputs, concatenated, context.allocator)
    testing.expect(t, automatic_score <= representative_score,
        "automatic strategy must not regress from representative sampling")
    testing.expect(t, automatic_score <= concatenated_score,
        "automatic strategy must not regress from concatenation")

    reference, encoder, err := encoder_create_from_inputs(
        inputs,
        Reference_Options{max_size = 8, strategy = .Frequent_Substrings},
        default_options(.GDC_Relative),
    )
    testing.expect_value(t, err, Error.None)
    module, encode_err := encode_indexed(&encoder, inputs[0])
    testing.expect_value(t, encode_err, Error.None)
    output := make([]u8, len(inputs[0]))
    testing.expect_value(t, decode_cpu(reference, &module, output), Error.None)
    expect_bytes_equal(t, output, inputs[0])
    delete(output)
    module_destroy(&module)
    encoder_destroy(&encoder)
    delete(reference)
}

@(test)
test_reference_builder_custom_allocator_ownership :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    allocator := mem.tracking_allocator(&track)
    inputs := [][]u8{
        {'r','e','p','e','a','t','e','d','-','d','a','t','a'},
        {'d','a','t','a','-','r','e','p','e','a','t','e','d'},
        {'o','t','h','e','r','-','d','a','t','a'},
    }

    for strategy in Reference_Strategy.Automatic..=Reference_Strategy.Coverage_Optimized {
        reference, build_err := reference_build(inputs, Reference_Options{
            max_size = 17,
            strategy = strategy,
        }, allocator)
        testing.expect_value(t, build_err, Error.None)
        encoder := encoder_create(reference, default_options(.GDC_Relative), allocator)
        for input in inputs {
            module, encode_err := encode_indexed(&encoder, input, allocator)
            testing.expect_value(t, encode_err, Error.None)
            archive, serialize_err := serialize(&module, allocator)
            testing.expect_value(t, serialize_err, Error.None)
            restored, restore_err := deserialize(archive, reference, {}, allocator)
            testing.expect_value(t, restore_err, Error.None)
            output := make([]u8, len(input), allocator)
            decoder := cpu_decoder()
            testing.expect_value(t, decode(&decoder, reference, &restored, output), Error.None)
            expect_bytes_equal(t, output, input)
            delete(output, allocator)
            module_destroy(&restored)
            delete(archive, allocator)
            module_destroy(&module)
        }
        encoder_destroy(&encoder)
        delete(reference, allocator)
    }
    testing.expect(t, track.current_memory_allocated == 0,
        "all custom-allocator reference-builder storage must be released")
}

@(test)
test_scalar_and_simd_decoders_match :: proc(t: ^testing.T) {
    reference := []u8{'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p'}
    input := []u8{
        'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
        'x','y',
        'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
    }
    module, err := encode_format(reference, input, .RLZ)
    defer module_destroy(&module)
    testing.expect_value(t, err, Error.None)
    scalar := make([]u8, len(input))
    vector := make([]u8, len(input))
    defer delete(scalar)
    defer delete(vector)
    testing.expect_value(t, decode_cpu_scalar(reference, &module, scalar), Error.None)
    testing.expect_value(t, decode_cpu_simd(reference, &module, vector), Error.None)
    expect_bytes_equal(t, vector, scalar)
}
