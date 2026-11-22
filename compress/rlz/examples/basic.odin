package main

import "core:fmt"
import rlz "../"

main :: proc() {
    reference := []u8{'A','B','C','D','E','F','G','H','I','J','K','L'}
    input := []u8{'A','B','C','D','X','Y','K','L','A','B','C','D'}

    options := rlz.DEFAULT_OPTIONS
    options.format = .RLZAP
    encoder := rlz.encoder_create(reference, options)
    defer rlz.encoder_destroy(&encoder)

    compressed, err := rlz.encode_indexed(&encoder, input)
    if err != .None { fmt.println("encode error:", err); return }
    defer rlz.module_destroy(&compressed)

    output := make([]u8, len(input))
    defer delete(output)

    decoder := rlz.decoder_create(reference)
    defer rlz.decoder_destroy(&decoder)
    err = rlz.decode(&decoder, reference, &compressed, output)
    fmt.println("decode error:", err, " matches:", string(output) == string(input))

    range_output := make([]u8, 4)
    defer delete(range_output)
    err = rlz.decode_range(&decoder, reference, &compressed, 4, 4, range_output)
    fmt.println("range decode:", string(range_output), " error:", err)
}
