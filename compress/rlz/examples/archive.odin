package main

import "core:fmt"
import "core:math/bits"
import rlz "../"

// This is an application archive format, not an rlz package format.
ARCHIVE_HEADER_SIZE :: 24
ARCHIVE_ENTRY_SIZE  :: 16
ARCHIVE_VERSION     :: u8(1)
INT_MAX             :: bits.INT_MAX

Archive_Entry :: struct {
    offset: u64,
    size:   u64,
}

Archive_Layout :: struct {
    reference: []u8,
    count:     int,
}

Archive_Error :: enum {
    None,
    Codec_Error,
    Invalid_Archive,
    Limit_Exceeded,
}

put_u64_le :: proc(data: []u8, at: int, value: u64) {
    for shift := 0; shift < 64; shift += 8 {
        data[at+shift/8] = u8(value >> u64(shift))
    }
}

get_u64_le :: proc(data: []u8, at: int) -> (u64, bool) {
    if at < 0 || at > len(data)-8 { return 0, false }
    value: u64
    for shift := 0; shift < 64; shift += 8 {
        value |= u64(data[at+shift/8]) << u64(shift)
    }
    return value, true
}

build_archive :: proc(inputs: [][]u8) -> (archive: []u8, err: Archive_Error) {
    reference, codec_err := rlz.reference_build(inputs, rlz.Reference_Options{
        max_size = 64*1024,
        strategy = .Automatic,
    })
    if codec_err != .None { return nil, .Codec_Error }
    defer delete(reference)

    encoder := rlz.encoder_create(reference, rlz.default_options(.GDC_Relative))
    defer rlz.encoder_destroy(&encoder)

    payloads := make([dynamic][]u8, 0, len(inputs))
    defer {
        for payload in payloads { delete(payload) }
        delete(payloads)
    }

    payload_bytes: u64 = 0
    for input in inputs {
        module, encode_err := rlz.encode_indexed(&encoder, input)
        if encode_err != .None {
            rlz.module_destroy(&module)
            return nil, .Codec_Error
        }

        payload, serial_err := rlz.serialize(&module)
        rlz.module_destroy(&module)
        if serial_err != .None { return nil, .Codec_Error }
        if payload_bytes > ~u64(0)-u64(len(payload)) {
            delete(payload)
            return nil, .Limit_Exceeded
        }
        payload_bytes += u64(len(payload))
        append(&payloads, payload)
    }

    if u64(len(inputs)) > (u64(INT_MAX)-ARCHIVE_HEADER_SIZE)/ARCHIVE_ENTRY_SIZE {
        return nil, .Limit_Exceeded
    }
    prefix_size := u64(ARCHIVE_HEADER_SIZE) +
        u64(len(inputs))*u64(ARCHIVE_ENTRY_SIZE) + u64(len(reference))
    if prefix_size > u64(INT_MAX) || payload_bytes > u64(INT_MAX)-prefix_size {
        return nil, .Limit_Exceeded
    }

    archive = make([]u8, int(prefix_size+payload_bytes))
    copy(archive[0:4], "RLZA")
    archive[4] = ARCHIVE_VERSION
    put_u64_le(archive, 8, u64(len(inputs)))
    put_u64_le(archive, 16, u64(len(reference)))

    directory_end := ARCHIVE_HEADER_SIZE+len(inputs)*ARCHIVE_ENTRY_SIZE
    copy(archive[directory_end:directory_end+len(reference)], reference)
    cursor := u64(directory_end+len(reference))
    for payload, index in payloads {
        entry_at := ARCHIVE_HEADER_SIZE+index*ARCHIVE_ENTRY_SIZE
        put_u64_le(archive, entry_at, cursor)
        put_u64_le(archive, entry_at+8, u64(len(payload)))
        copy(archive[int(cursor):int(cursor)+len(payload)], payload)
        cursor += u64(len(payload))
    }
    return archive, .None
}

open_archive :: proc(data: []u8) -> (layout: Archive_Layout, err: Archive_Error) {
    if len(data) < ARCHIVE_HEADER_SIZE ||
       string(data[0:4]) != "RLZA" ||
       data[4] != ARCHIVE_VERSION ||
       data[5] != 0 || data[6] != 0 || data[7] != 0 {
        return {}, .Invalid_Archive
    }

    count_u64, ok1 := get_u64_le(data, 8)
    reference_size, ok2 := get_u64_le(data, 16)
    if !ok1 || !ok2 ||
       count_u64 > u64((len(data)-ARCHIVE_HEADER_SIZE)/ARCHIVE_ENTRY_SIZE) {
        return {}, .Invalid_Archive
    }

    count := int(count_u64)
    reference_at := ARCHIVE_HEADER_SIZE+count*ARCHIVE_ENTRY_SIZE
    if reference_size > u64(len(data)-reference_at) {
        return {}, .Invalid_Archive
    }
    reference_end := reference_at+int(reference_size)

    expected_at := u64(reference_end)
    for index in 0..<count {
        entry_at := ARCHIVE_HEADER_SIZE+index*ARCHIVE_ENTRY_SIZE
        offset, offset_ok := get_u64_le(data, entry_at)
        size, size_ok := get_u64_le(data, entry_at+8)
        if !offset_ok || !size_ok ||
           offset != expected_at ||
           size > u64(len(data))-offset {
            return {}, .Invalid_Archive
        }
        expected_at += size
    }
    if expected_at != u64(len(data)) { return {}, .Invalid_Archive }

    return Archive_Layout{
        reference = data[reference_at:reference_end],
        count = count,
    }, .None
}

archive_entry :: proc(data: []u8, index: int) -> (Archive_Entry, Archive_Error) {
    layout, open_err := open_archive(data)
    if open_err != .None { return {}, open_err }
    if index < 0 || index >= layout.count { return {}, .Invalid_Archive }

    entry_at := ARCHIVE_HEADER_SIZE+index*ARCHIVE_ENTRY_SIZE
    offset, _ := get_u64_le(data, entry_at)
    size, _ := get_u64_le(data, entry_at+8)
    return Archive_Entry{offset = offset, size = size}, .None
}

archive_extract :: proc(
    data: []u8,
    index: int,
    maximum_output: u64 = 64*1024*1024,
) -> (output: []u8, err: Archive_Error) {
    layout, open_err := open_archive(data)
    if open_err != .None { return nil, open_err }
    entry, entry_err := archive_entry(data, index)
    if entry_err != .None { return nil, entry_err }
    payload := data[int(entry.offset):int(entry.offset+entry.size)]

    module, codec_err := rlz.deserialize(payload, layout.reference,
        rlz.Deserialize_Options{maximum_output = maximum_output})
    if codec_err != .None { return nil, .Codec_Error }
    defer rlz.module_destroy(&module)

    decoded_size, size_err := rlz.decoded_size(&module)
    if size_err != .None || u64(decoded_size) > maximum_output {
        return nil, .Limit_Exceeded
    }
    output = make([]u8, decoded_size)
    decoder := rlz.decoder_create(layout.reference)
    defer rlz.decoder_destroy(&decoder)
    if rlz.decode(&decoder, layout.reference, &module, output) != .None {
        delete(output)
        return nil, .Codec_Error
    }
    return output, .None
}

same_bytes :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) { return false }
    for value, index in a {
        if value != b[index] { return false }
    }
    return true
}

main :: proc() {
    inputs := [][]u8{
        {'c','o','m','m','o','n',':','a','l','p','h','a',0,255},
        {'c','o','m','m','o','n',':','b','e','t','a',0,255},
        {'a','n','o','t','h','e','r',' ','r','e','c','o','r','d'},
    }

    archive, build_err := build_archive(inputs)
    if build_err != .None {
        fmt.println("archive construction failed:", build_err)
        return
    }
    defer delete(archive)

    for input, index in inputs {
        recovered, extract_err := archive_extract(archive, index)
        if extract_err != .None {
            fmt.println("archive extraction failed:", index, extract_err)
            return
        }
        if !same_bytes(recovered, input) {
            fmt.println("round trip failed:", index)
            delete(recovered)
            return
        }
        delete(recovered)
    }
    fmt.printf("round-tripped %d modules from one %d-byte archive\n",
        len(inputs), len(archive))
}
