# Relative Lempel-Ziv for Odin

`rlz` compresses independent binary buffers against a shared reference. It
provides four codecs (`RLZ`, `GDC`, `GDC_Relative`, and `RLZAP`), CPU decoding,
an OpenGL compute backend, and a low-level Vulkan command recorder.

The package does **not** define a container for several compressed inputs. Each
call to `serialize` serializes exactly one `Module`. This README includes a
complete caller-owned archive format in
[`examples/archive.odin`](examples/archive.odin).

## Quick Start

Build a shared reference, create its search index once, and use that encoder for
several inputs:

```odin
inputs := [][]u8{
    {'c','o','m','m','o','n',':','a','l','p','h','a'},
    {'c','o','m','m','o','n',':','b','e','t','a'},
}

reference, build_err := rlz.reference_build(inputs, rlz.Reference_Options{
    max_size = 256*1024,
    strategy = .Automatic,
})
if build_err != .None { return }
defer delete(reference)

encoder := rlz.encoder_create(reference, rlz.default_options(.GDC_Relative))
defer rlz.encoder_destroy(&encoder)

decoder := rlz.decoder_create(reference)
defer rlz.decoder_destroy(&decoder)

for input in inputs {
    module, encode_err := rlz.encode_indexed(&encoder, input)
    if encode_err != .None { return }
    defer rlz.module_destroy(&module)

    encoded_bytes, serial_err := rlz.serialize(&module)
    if serial_err != .None { return }
    defer delete(encoded_bytes)

    restored, load_err := rlz.deserialize(encoded_bytes, reference,
        rlz.Deserialize_Options{maximum_output = 64*1024*1024})
    if load_err != .None { return }
    defer rlz.module_destroy(&restored)

    output := make([]u8, int(restored.output_size))
    if rlz.decode(&decoder, reference, &restored, output) != .None {
        delete(output)
        return
    }
    defer delete(output)
}
```

This snippet borrows `inputs` while building and encoding. It owns and frees
`reference`, each in-memory module, each serialized module, and every output.
For repeated work, keep the `Encoder` and `Decoder` values alive and reuse them.
Production code should process a collection incrementally rather than retaining
all `defer`ed allocations until the surrounding procedure returns.

## End-to-End Multi-Module Archive Example

This is a complete, self-contained application that:

1. builds one optimised reference from `[][]u8`;
2. encodes and serializes every input independently;
3. writes the reference, a directory of offsets and sizes, and all serialized
   modules into one `[]u8`;
4. validates the complete archive layout;
5. selects a module by directory index;
6. deserializes it and reconstructs the original bytes.

The archive layout is deliberately documented as application code. `rlz` does
not read or write it.

| Offset | Content |
|---:|---|
| 0 | four bytes `RLZA` |
| 4 | one-byte version, currently `1` |
| 5 | three zero reserved bytes |
| 8 | `u64le` module count |
| 16 | `u64le` reference byte length |
| 24 | count entries, each `u64le offset`, `u64le size` |
| after directory | raw shared reference |
| directory offsets | exact serialized module bytes, back-to-back |

Save this as `compress\rlz\examples\archive.odin` and run it from the repository
root with:

```text
odin run compress\rlz\examples\archive.odin -file -vet -warnings-as-errors
```

It is also kept as executable source in
[`examples/archive.odin`](examples/archive.odin).

```odin
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
```

The reader calls `open_archive` before converting any archive offset to `int`.
It rejects:

- truncated or bad headers;
- impossible directory counts;
- reference ranges outside the buffer;
- module offsets that are not contiguous after the reference;
- sizes that overflow or leave the buffer;
- trailing bytes not described by the directory.

The package-level codec still validates the selected serialized module, including
reference fingerprint, phrase bounds, literal counts, version, output limits,
and varint overflow. The archive reader must add any application-specific file,
name, checksum, authentication, compression-level, or size policy.

## Core Concepts and Data Formats

### Reference bytes and reference index

A **reference** is an ordinary borrowed `[]u8`. It is external to every module;
modules contain only a 64-bit fingerprint plus copy locations. Decoding therefore
requires the original reference bytes (or byte-identical reconstructed bytes).

A **reference index** is the suffix ordering used to find matches during
encoding. `Encoder` owns an index. It is an implementation/cache object, not a
serialized archive component, and is never needed to decode.

The fingerprint returned by `reference_id` is FNV-1a64 with the reference
length mixed in. It detects accidental mismatches but is not cryptographic
integrity or authentication. Collision-free behavior is not guaranteed.

### `Encoder` versus `Module`

An `Encoder`:

- borrows a reference slice;
- owns a `Reference_Index`;
- stores `Encode_Options`;
- is reused to encode many independent inputs.

A `Module`:

- owns a dynamic phrase array and literal-byte array;
- stores decoded/output size, format, and reference fingerprint;
- contains one encoded target.

An encoder is not serialized, and a module is not a reference index. Do not
serialize `Encoder`, `Module`, `Phrase`, or pointers by copying Odin struct
memory; their dynamic arrays are process-local and their layout is not a
portable format.

### In-memory module versus serialized module

An in-memory `Module` is a normalized sequence of 16-byte `Phrase` values:

```odin
Phrase :: struct {
    output_offset: u32,
    source_offset: u32,
    length:        u32,
    kind:          Phrase_Kind,
}
```

`source_offset` addresses either the external reference or the module's literal
pool according to `kind`. `output_offset` addresses the decoded output. Phrase
offsets and lengths are byte-based and cover exactly `output_size`.

`serialize` emits portable bytes, while `deserialize` rebuilds an owned
in-memory module from exactly one serialized-module buffer. Extra/trailing bytes
make `deserialize` return `.Invalid_Stream`; pass a slice corresponding to one
directory entry.

An individual serialized module has this shape:

1. `RLZ1` magic;
2. version `1`;
3. `Format` as one byte;
4. little-endian `reference_id`;
5. ULEB128 decoded size;
6. ULEB128 phrase count;
7. ULEB128 literal count;
8. phrase records containing a kind/tag, pointer data, and ULEB128 length;
9. literal bytes.

Pointer representation depends on format: absolute ULEB128 for `RLZ`/`GDC`,
ZigZag ULEB128 displacements for relative formats, with repeat compression for
`GDC_Relative` and adaptive deltas for `RLZAP`. Reconstructed output offsets are
not stored in the portable stream.

### What `rlz` does not implement

The package has no archive/container API, no filenames, no module directory, no
archive framing, and no checksummed/authenticated reference storage.
`rlz.serialize` does not concatenate the reference or create a complete
multi-module archive. The caller must:

- store the reference if it must be portable or available later;
- define and version the outer archive;
- store module offsets and lengths;
- check integer conversions and every untrusted range;
- impose total archive, decompressed size, phrase-count, and literal-count
  limits;
- decide how to handle filenames, duplicate modules, checksums, authentication,
  and compatibility.

## Creating and Reusing Encoders

The normal multi-input path is:

```odin
encoder := rlz.encoder_create(reference, rlz.default_options(.RLZAP))
defer rlz.encoder_destroy(&encoder)

for input in inputs {
    module, err := rlz.encode_indexed(&encoder, input)
    if err != .None { return }
    // Use module before destroying it.
    rlz.module_destroy(&module)
}
```

The encoder borrows `reference`; do not mutate or free it until all encoding and
any bound decoder operations are complete. Encoder values and their mutable
reference indexes must not be shared concurrently. Separate encoders may be used
concurrently if their references and allocators are safe for that use.

For one target only, this convenience path creates and destroys the index
internally:

```odin
module, err := rlz.encode_format(reference, input, .GDC)
```

`encode` is a shorter `RLZ`-only convenience.

`encode_into(&encoder, input, &module)` builds a replacement module, destroys the
old `module` arrays, and assigns the replacement. On encoding failure, the old
target is left intact.

## Compression Formats

| Format | Encoding behavior | Serialized pointer behavior | Best default use |
|---|---|---|---|
| `RLZ` | Greedy longest reference copies of at least `minimum_reference_match`; unmatched bytes are emitted one at a time as literals | Absolute source offset per reference phrase | Simple baseline and compatibility/debugging |
| `GDC` | Greedy longest copy followed by the mismatching target byte as a literal, then continue; otherwise groups literals | Absolute source offset | Often fewer phrases than `RLZ` around copy boundaries |
| `GDC_Relative` | Same phrase selection as `GDC` | Signed source/output displacement; a repeated displacement omits pointer bytes | Preferred starting point when repeated offsets occur |
| `RLZAP` | Explicit displacement references plus bounded adaptive deltas; includes lookahead, literal-run cap, and an explicit adaptive match threshold | ZigZag displacement/delta encoding | Try when pointer changes are small or when tuning is worthwhile |

All four share the same in-memory normalized phrase form. After
deserialization, decoding does not dispatch a different CPU algorithm by
format; pointer differences matter during serialization.

### `Encode_Options`

```odin
Encode_Options :: struct {
    format:   Format,
    minimum_reference_match: int,
    rlzap:    RLZAP_Options,
}

RLZAP_Options :: struct {
    look_ahead:   int,
    delta_bits:   int,
    explicit_len: int,
    max_literals: int,
}
```

`default_options(format)` and `DEFAULT_OPTIONS` use:

| Field | Default |
|---|---:|
| `minimum_reference_match` | 4 |
| `look_ahead` | 16 |
| `delta_bits` | 8 |
| `explicit_len` | 4 |
| `max_literals` | 255 |

`encoder_create` normalizes invalid values rather than returning an error:

- nonpositive `minimum_reference_match` becomes `4`;
- `delta_bits <= 0` or `>= 63` becomes `8`;
- nonpositive `explicit_len` becomes `4`;
- nonpositive `max_literals` becomes `255`;
- negative `look_ahead` becomes `0`.

Option applicability:

- `minimum_reference_match` controls every format's normal greedy path.
  RLZAP's first/bounded adaptive path also requires `explicit_len`; a valid
  adaptive candidate can therefore be shorter than `minimum_reference_match`.
- `look_ahead` postpones a reference phrase if a one-byte literal allows a match
  more than that many bytes longer. It affects `RLZAP` only.
- `delta_bits` limits the signed adaptive pointer delta. It affects RLZAP
  phrase representation only.
- `explicit_len` is RLZAP's threshold for considering an explicit/adaptive
  reference phrase.
- `max_literals` caps an unmatched literal run and affects `RLZAP` only.
- `format` is authoritative on the encoder. `encode_format` overwrites its local
  options format with the explicit `format` argument.

## Shared Reference Construction

`reference_build(inputs, Reference_Options{...})` returns an owned `[]u8`. Inputs
are only borrowed for the duration of construction. The returned reference must
be preserved alongside modules that use it and must remain immutable while an
encoder or decoder uses it.

```odin
Reference_Options :: struct {
    max_size: int,
    strategy: Reference_Strategy,
}
```

### `max_size`

- `0` means the **1 MiB default** (`1_048_576`), not unlimited.
- a negative size returns `.Invalid_Argument`;
- values above `0xffffffff` return `.Limit_Exceeded`;
- the resulting reference is no longer than the selected limit;
- an automatic run may choose an empty reference if a reference does not improve
  the objective.

### Strategies

| Strategy | Deterministic construction |
|---|---|
| `Representative_Sampling` | Takes 256-byte regions distributed across inputs, skips byte-identical chunks already present, and fills remaining space from input prefixes. |
| `Frequent_Substrings` | Hash-samples 16-byte windows, deduplicates equal windows, scores `count * length`, and appends highest-frequency candidates. |
| `Coverage_Optimized` | Samples 12-byte windows and favors candidates that add unseen 4-byte coverage across inputs. |
| `Automatic` | Builds representative, frequent-substring, coverage-optimized, and concatenation candidates, plus an empty-reference candidate, then selects the exact smallest total. |

Automatic's score is:

```text
len(reference)
+ serialized module sizes for every input and all four formats
```

It does not optimize only the eventual format configured on your encoder. It can
be expensive: it constructs candidates and performs indexed encodings for all
four formats. Ties prefer the smaller reference. For offline corpus construction
the cost may be worthwhile; for latency-sensitive construction choose a
deterministic strategy.

`encoder_create_from_inputs` combines reference construction and encoder
creation. It returns both owned/reference-dependent values:

```odin
reference, encoder, err := rlz.encoder_create_from_inputs(
    inputs,
    rlz.Reference_Options{max_size = 64*1024, strategy = .Automatic},
    rlz.default_options(.GDC_Relative),
)
if err != .None { return }
defer delete(reference)
defer rlz.encoder_destroy(&encoder)
```

The cleanup order must be encoder/index first, then reference. Note that `defer`
calls run in reverse order: the code above destroys the encoder before deleting
the reference.

`build_reference` is a compatibility wrapper around representative sampling.
Its zero/negative `maximum_size` means 1 MiB and its zero/negative `chunk_size`
means 256. It returns `nil` without an error for checked-size failures, so
`reference_build` is preferred.

## CPU Decoding and Random Access

Allocate the decoded buffer yourself:

```odin
output := make([]u8, int(module.output_size))
defer delete(output)

decoder := rlz.cpu_decoder(64*1024*1024) // zero means no decoder-level limit
defer rlz.decoder_destroy(&decoder)
err := rlz.decode(&decoder, reference, &module, output)
```

`decode_cpu`, `decode_cpu_scalar`, and `decode_cpu_simd` perform the same task
without a `Decoder` value. The production scalar/SIMD behavior:

- `decode_cpu` and `Decoder` CPU mode use the scalar copy path;
- `decode_cpu_simd` optionally performs unaligned 16-byte operations when Odin
  reports hardware SIMD, then scalar-copies the tail;
- all paths validate the whole module before copying;
- validation and copying allocate no scratch/output storage.

`decode_range` uses CPU binary search to identify the first phrase for the range:

```odin
part := make([]u8, 128)
err := rlz.decode_range(&decoder, reference, &module, 4096, 128, part)
```

Only the requested bytes are copied. CPU and `Auto` support arbitrary subranges.
GPU, Vulkan, and OpenGL backends reject a subrange unless `start == 0` and
`length == module.output_size`; in that case they perform a full decode.

Output buffers may be larger than the decoded/range size. The functions do not
change bytes after the requested output. `decode_range` validates
`start + length` using `u64`, so a wrapping request returns an error.

`decoder_create(reference, backend, maximum_output)` fingerprints the reference
once and stores a bound fingerprint. `decode` checks that later modules and
reference arguments match it without hashing the reference every time. The
reference is still borrowed and must remain immutable.

## GPU Decoding

### Caller-provided callback

`gpu_decoder(callback, user_data)` creates a `.GPU` decoder. The callback
signature is:

```odin
GPU_Decode_Proc :: proc "odin" (
    user_data: rawptr,
    reference: []u8,
    module: ^Module,
    output: []u8,
) -> Error
```

The callback must:

- be an Odin calling-convention procedure;
- treat its inputs as borrowed and immutable;
- upload or otherwise consume reference/module data;
- validate source/backend requirements;
- submit GPU work;
- wait until `output` is CPU-readable;
- return an `Error` before the synchronous call completes.

No CPU fallback is performed for GPU, Vulkan, or OpenGL requests. `Auto` currently
selects CPU in `decode`; it does not probe a GPU.

### OpenGL

```odin
context, err := rlz.opengl_decoder_create()
if err != .None { return }
defer rlz.opengl_decoder_destroy(&context)

err = rlz.opengl_prepare_reference(&context, reference)
if err != .None { return }

decoder := rlz.opengl_gpu_decoder(&context)
err = rlz.decode(&decoder, reference, &module, output)
```

`opengl_decoder_create`:

- initializes GLFW globally;
- creates a hidden OpenGL 4.5 core window;
- compiles the embedded compute shader;
- creates SSBO and timestamp-query objects;
- returns `.Unsupported_Backend` or `.Backend_Failed` on setup failure.

The backend owns the GLFW lifecycle and is thread-affine. Use one context only
on its owner thread; do not integrate this procedure into an application-owned
OpenGL/GLFW lifecycle without adapting the resource ownership.

`opengl_prepare_reference` packs and uploads the reference once. A byte
fingerprint plus length cache is used to avoid another upload. Reference
storage remains resident until the fingerprint/size changes. Per-module literal,
phrase, and output capacity is retained across calls and may be inspected with
`opengl_allocated_bytes`.

The synchronous OpenGL decoder fills the caller's output before returning.
`opengl_decode_profiled` additionally reports nanosecond timings for
validation, literal preparation, upload, dispatch, synchronization, readback,
and the GPU timestamp duration. `opengl_decode_timed` returns only GPU elapsed
nanoseconds plus an error. Empty outputs return before dispatch.

The current provider requires output <= compute workgroup-count limits, OpenGL
persistent coherent buffer mappings, and CPU readback. Use CPU for small
latency-sensitive inputs.

### Vulkan

`gpu_vulkan.odin` is only a command recorder:

```odin
err := rlz.gpu_record_decode(
    command_buffer,
    &context,       // externally created Vulkan pipeline/layout/descriptors
    output_size,
    max_workgroup_count_x,
)
```

The caller must create the device, queues, pipeline, pipeline layout, SPIR-V,
descriptor set, buffers, memory bindings, and fences. Before recording:

- binding 0 must contain packed reference `u32` words;
- binding 1 must contain packed literal words;
- binding 2 must contain 16-byte `Phrase` records;
- binding 3 must contain at least `ceil(output_size/4)*4` output bytes;
- a 4-byte push constant must be valid at the pipeline layout.

The command buffer must be in recording state outside a render pass. The caller
owns host-to-compute and compute-to-host barriers, memory visibility and
invalidation, submission, synchronization, queue selection, and readback.

The package currently does **not** create Vulkan resources or provide a Vulkan
`GPU_Decode_Proc`, so a normal `.Vulkan` `Decoder` without a callback returns
`.Unsupported_Backend`.

Build the shader included in `shaders/decode.comp.glsl` with:

```text
glslangValidator -V -S comp shaders/decode.comp.glsl -o shaders/decode.comp.spv
```

## API Reference

Allocator behavior follows Odin's normal allocator model. `make`/`append`/
buffer packing in this package do not convert allocator failures to `Error`;
the caller's allocator policy (which may panic or use an alternative mechanism)
still applies. Package `Error` values describe argument, stream, backend, and
limit failures, not failed heap allocation. When supplying a custom allocator,
delete returned buffers with that allocator or through destroy functions that
retain/use their allocator.

### Enums and data types

| Symbol | Meaning |
|---|---|
| `Format` | `.RLZ`, `.GDC`, `.GDC_Relative`, `.RLZAP`. |
| `Backend` | `.CPU`, `.GPU`, `.Vulkan`, `.OpenGL`, `.Auto`. |
| `Phrase_Kind` | `.Reference`, `.Literal`, `.Reference_Adaptive`. |
| `Phrase` | 16-byte in-memory normalized phrase; its ABI is retained for Vulkan. |
| `Module` | Owned phrases/literals plus `output_size`, `format`, and `reference_id`. |
| `Encoder` | Borrowed reference, owned suffix index, and options. |
| `Decoder` | Backend/callback/limits and optionally a bound reference fingerprint. |
| `Reference_Index` | Borrowed reference, owned suffix array, and its allocator. |
| `Error` | `.None`, `.Invalid_Argument`, `.Invalid_Stream`, `.Output_Too_Small`, `.Unsupported_Version`, `.Unsupported_Backend`, `.Backend_Failed`, `.Limit_Exceeded`, `.Truncated`, `.Reference_Mismatch`. |
| `Deserialize_Options` | `maximum_output`, `maximum_phrases`, and `maximum_literals`; zero activates each documented default. |
| `Reference_Strategy` | Automatic, representative, frequent, or coverage-optimized construction. |
| `Reference_Options` | `max_size` and construction `strategy`. |
| `Reference_Builder_Options` | Compatibility `maximum_size` and `chunk_size`. |
| `OpenGL_Context` | Standalone context/resources/cache state; opaque-by-convention. |
| `OpenGL_Profile` | Validation/preparation/upload/dispatch/synchronization/readback and GPU-kernel timings. |
| `GPU_Context` | Caller-owned Vulkan pipeline, layout, and descriptor set handles. |

`SERIAL_MAGIC` is `{'R','L','Z','1'}` and `SERIAL_VERSION` is `1`.
`DEFAULT_OPTIONS` is the literal default `Encode_Options` value;
`default_options(format)` returns a value copy with the selected format.

### Reference and index APIs

| Signature | Contract |
|---|---|
| `reference_build(inputs, options = {}, allocator = context.allocator) -> ([]u8, Error)` | Returns an owned reference. `max_size == 0` becomes 1 MiB. Inputs are borrowed; delete the returned slice. |
| `encoder_create_from_inputs(inputs, reference_options = {}, encode_options = DEFAULT_OPTIONS, allocator = context.allocator) -> ([]u8, Encoder, Error)` | Builds both values using one allocator. Destroy encoder before deleting reference. On failure, temporary construction storage is released. |
| `build_reference(inputs, Reference_Builder_Options = {}, allocator = context.allocator) -> []u8` | Compatibility representative sampler. It has no error channel and returns `nil` on checked-size failure. |
| `reference_id(reference) -> u64` | Pure FNV-like fingerprint including length; does not allocate. |
| `index_create(reference, allocator = context.allocator) -> Reference_Index` | Allocates one suffix entry per reference byte and sorts suffixes. Borrows reference. No error return. |
| `index_destroy(&index)` | Frees the suffix array with the allocator stored by the index and zeros the value. |
| `longest_match(&index, input, input_at) -> (source_at, length)` | Returns the longest indexed match and lowest source on a tie. Expects `input_at` in range; does not allocate. |
| `matching_statistics(&index, input, allocator = context.allocator) -> ([]int, []int)` | Returns owned source/length arrays, one entry per input byte. The caller deletes both. |

Suffix construction currently uses Odin's generic sort plus repeated suffix
comparisons. Peak index storage is approximately `len(reference) * size_of(int)`,
and sorting highly repetitive/large references can be substantially more
expensive than linear time.

### Encoding APIs

| Signature | Contract |
|---|---|
| `encoder_create(reference, options = DEFAULT_OPTIONS, allocator = context.allocator) -> Encoder` | Builds and owns a reference index; normalizes invalid option fields described above. |
| `encoder_destroy(&encoder)` | Frees the index and zeros the encoder. The reference is not freed. |
| `encode_indexed(&encoder, input, allocator = context.allocator) -> (Module, Error)` | Encodes one input using the existing index. On success the caller owns the module arrays. |
| `encode_into(&encoder, input, &target, allocator = context.allocator) -> Error` | Encodes to a temporary owned module; on success destroys/replaces `target`. |
| `encode_format(reference, input, format, options = DEFAULT_OPTIONS, allocator = context.allocator) -> (Module, Error)` | One-shot API: constructs an index, encodes, and destroys the index before returning. Explicit `format` overrides `options.format`. |
| `encode(reference, input, allocator = context.allocator) -> (Module, Error)` | Equivalent to one-shot `RLZ` encoding with default options. |
| `encode_format_indexed(&encoder, input, allocator) -> (Module, Error)` | Lower-level indexed encoder entry; public but normally use `encode_indexed`. It requires an explicitly supplied allocator. |
| `module_destroy(&module)` | Frees phrase/literal arrays and zeros the module. Safe on `nil`. |

Encoding validates reference and input lengths against the 32-bit in-memory
output/address limit. It returns `.Invalid_Argument` if either exceeds
`0xffffffff`. It returns owned arrays even for an empty module.

### Serialization APIs

| Signature | Contract |
|---|---|
| `serialized_size(&module) -> (int, Error)` | Returns exact portable byte length without allocating output. Validates structural/format assumptions it can check without a reference. |
| `serialize(&module, allocator = context.allocator) -> ([]u8, Error)` | Allocates and returns one portable module. Delete the result with its allocator. |
| `serialize_into(&module, output) -> (written, Error)` | Writes into caller storage. Returns required size plus `.Output_Too_Small` when too short. Checks phrase sequence/output structure, but cannot check reference bounds because no reference is passed. |
| `deserialize(data, reference, options = {}, allocator = context.allocator) -> (Module, Error)` | Parses exactly `data`, checks fingerprint and all phrase/literal ranges, and returns an owned module. |

Default deserialization limits are:

- output: `4*u64(0x40000000)` (16 GiB), with a separate stream-level u32
  maximum;
- phrase count: 16,000,000;
- literal count: `maximum_output`.

Set explicit limits for untrusted files. Errors include `.Truncated`,
`.Invalid_Stream`, `.Unsupported_Version`, `.Reference_Mismatch`, and
`.Limit_Exceeded`. Deserialization destroys partial module storage on all
post-allocation error paths.

The stream rejects extra bytes. It also rejects empty phrases, unknown phrase
kinds, invalid GDC-RLZAP pointer state, overflowing i64 displacement arithmetic,
incomplete output coverage, and reference/literal source ranges outside their
buffers.

### Decoding and inspection APIs

| Signature | Contract |
|---|---|
| `cpu_decoder(maximum_output = 0) -> Decoder` | Unbound CPU decoder. Zero means unlimited at decoder level. |
| `decoder_create(reference, backend = .CPU, maximum_output = 0) -> Decoder` | Binds a reference fingerprint without owning the reference. For GPU use, prefer a real provider adapter such as `opengl_gpu_decoder`. |
| `gpu_decoder(callback, user_data = nil) -> Decoder` | Creates a `.GPU` synchronous callback decoder; no output limit is set. |
| `decoder_destroy(&decoder)` | Zeros the value; it does not own GPU context or free callback data. |
| `decode(&decoder, reference, &module, output) -> Error` | Validates and dispatches whole-buffer decoding. `output` must be at least `module.output_size`. |
| `decode_into` | Exact alias behavior for `decode`; same parameters and result. |
| `decode_cpu(reference, &module, output) -> Error` | Validated scalar CPU decode; no temporary allocation. |
| `decode_cpu_scalar` | Explicit scalar path for comparison/testing. |
| `decode_cpu_simd` | Explicit SIMD-capable copy path for comparison/testing; byte-identical to scalar. |
| `decode_range(&decoder, reference, &module, start, length, output) -> Error` | CPU random-access copy; output must be at least `length`. GPU supports only a full output range. |
| `decode_range_cpu(reference, &module, start, length, output) -> Error` | Direct CPU range API. |
| `decoded_size(&module) -> (int, Error)` | Returns the decoded allocation length. Returns `.Invalid_Argument` for nil. |
| `validate(reference, &module) -> bool` | Checks fingerprint, phrase order/coverage, phrase kinds, and all source ranges. |
| `phrase_at(&module, position) -> (index, bool)` | Binary-search helper. False for nil/empty module or `position >= output_size`. |

`validate_without_reference`, `decode_cpu_unchecked`, and
`decode_cpu_unchecked_mode` are lower-level package-visible implementation
helpers. They skip the full reference fingerprint and/or validation work and
must only receive modules already validated for the exact reference. Prefer
`decode`, `decode_cpu`, or one of the explicit checked CPU paths.

### GPU APIs

| Signature | Contract |
|---|---|
| `opengl_decoder_create() -> (OpenGL_Context, Error)` | Creates hidden OpenGL 4.5/GLFW state and compiles/allocates resources. |
| `opengl_decoder_destroy(&context)` | Deletes GL/GLFW resources and owned CPU scratch arrays. |
| `opengl_prepare_reference(&context, reference) -> Error` | Validates ownership/thread state and packs/uploads a changed reference. |
| `opengl_decode_profiled(&context, reference, &module, output) -> (OpenGL_Profile, Error)` | Synchronous profiled decode with CPU-visible output. |
| `opengl_decode_timed(&context, reference, &module, output) -> (gpu_kernel_ns, Error)` | Synchronous decode returning the GPU timestamp duration. |
| `opengl_decode(&context, reference, &module, output) -> Error` | Synchronous OpenGL decode without profile result. |
| `opengl_gpu_callback(user_data, reference, &module, output) -> Error` | Adapter with the `GPU_Decode_Proc` calling convention. |
| `opengl_gpu_decoder(&context) -> Decoder` | `.OpenGL` decoder using that adapter. |
| `opengl_allocated_bytes(&context) -> int` | Retained GPU capacities plus packed-reference size. |
| `gpu_record_decode(cmd, &GPU_Context, output_size, max_workgroup_count_x) -> Error` | Records pipeline/descriptor/push-constant/dispatch calls into an externally managed Vulkan command buffer. |

All OpenGL public entry points require a valid context and same-owner thread.
Neither OpenGL nor Vulkan operations are safe to race on one mutable context.
The returned `Decoder` does not own the OpenGL context; destroy the decoder
independently/then the context after decoding stops.

### Exposed low-level helpers

Odin currently gives all package-level declarations the same visibility; this
package also exposes helpers used to implement reference construction,
serialization, and byte packing. They are package internals by convention and
are not recommended as stable application APIs:

- module helpers: `new_module`, `append_literal`, `append_reference`;
- validation/errors: `validate_sizes`, `invalid_reference_error`,
  `validate_without_reference`;
- search/copy helpers: `compare_suffix`, `match_at`, `copy_decode_bytes`;
- reference-builder state/helpers: `Reference_Candidate`, `Reference_Hash`,
  `Reference_Candidate_Sort`, `Coverage_Set`, `contains_chunk`,
  `candidate_less`, `bytes_less`, `sort_reference_candidates`,
  `reference_window_hash`, `same_candidate_bytes`,
  `collect_reference_candidates`, `append_candidate_reference`,
  coverage-set create/slot/query/insert/destroy helpers, `candidate_has_new_coverage`,
  `mark_candidate_coverage`, `build_representative_reference`,
  `build_scored_reference`, `build_concatenated_reference`,
  `checked_reference_size`, and `reference_score`;
- serialization helpers: `uleb_size`, `append_uleb`, `read_uleb`, `zigzag`,
  `unzigzag`, and `checked_add_i64`;
- GPU packing/upload helper: `pack_bytes` and `opengl_map_storage`;
- the `OPENGL_COMPUTE_SHADER` source string and reference-sort scratch structs.

For correctness and compatibility, use the documented reference, encoder,
serialization, decoder, and backend lifecycle APIs rather than those helpers.
They may allocate using supplied allocators, assume prevalidated indexes/ranges,
or operate on partially constructed state.

## Memory Ownership and Lifetimes

| Value | Ownership and lifetime |
|---|---|
| Input slices | Caller-owned; reference builder and encoder borrow them. |
| Reference returned by `reference_build` / `encoder_create_from_inputs` | Caller-owned; delete after every encoder/decoder that depends on it. |
| Literal reference slice passed to `encoder_create` | Caller-owned and borrowed. |
| Encoder | Owns its suffix index; `encoder_destroy` before deleting the borrowed reference. |
| Module returned by encoding/deserialization | Caller-owned phrase/literal arrays; call `module_destroy`. |
| Serialized `[]u8` from `serialize` | Caller-owned; delete with the allocation allocator. |
| `serialize_into` destination | Caller-owned; function borrows it only during the call. |
| Decoded output | Caller-owned; allocate to decoded size; CPU/GPU decoders do not own it. |
| Decoder | No allocated resource itself. `decoder_destroy` only zeros/breaks bindings. |
| OpenGL context | Owns GLFW/GL resources and CPU scratch; destroy from its owner thread. |
| Vulkan handles | Application-owned; `gpu_record_decode` only records commands. |
| Archive view slices | Borrow the contiguous archive buffer; keep the archive alive. |

For custom allocators, pass the same allocator consistently to all operations
that need persistent storage and to `delete` of returned plain slices:

```odin
reference, err := rlz.reference_build(inputs, options, allocator)
defer delete(reference, allocator)

encoder := rlz.encoder_create(reference, options2, allocator)
defer rlz.encoder_destroy(&encoder)

module, err2 := rlz.encode_indexed(&encoder, inputs[0], allocator)
defer rlz.module_destroy(&module)

bytes, err3 := rlz.serialize(&module, allocator)
defer delete(bytes, allocator)
```

Module and index destroyers know/use their stored dynamic allocation allocator;
do not free their internals manually.

### Threading

Modules, literal/reference data, and serialized bytes may be shared for
concurrent reads when immutable. Independent decoders, encoders, and
allocators may be used concurrently. Do not concurrently mutate one `Encoder`,
`Module`, `Reference_Index`, `OpenGL_Context`, or mutable `Decoder`. Do not
mutate a reference while an encoder/index/decoder or GPU upload cache can observe
it.

## Error Handling and Troubleshooting

| Error | Typical cause / action |
|---|---|
| `Invalid_Argument` | Nil required pointer, invalid range/limit, oversized in-memory length, or impossible Vulkan dispatch count. Check dimensions and pointers. |
| `Invalid_Stream` | Malformed module structure, bad phrase/tag/varint, source range, trailing data, or structural coverage. Do not decode it. |
| `Output_Too_Small` | Allocate `module.output_size` for whole decode or `length` for a range; `serialize_into` reports the required size. |
| `Unsupported_Version` | Serialized module version is not 1. Implement a version policy in the outer archive reader. |
| `Unsupported_Backend` | Missing callback, GPU range request, unavailable OpenGL context, or non-CPU `Auto` expectation. No fallback occurs. |
| `Backend_Failed` | GPU allocation, shader, GL, mapping, query, or submit/readback operation failed. Inspect the provider. |
| `Limit_Exceeded` | Builder, serialized declaration, decoder, phrase count, literal count, or GPU workgroup limit exceeded. |
| `Truncated` | Not enough bytes for the serialized header/varint/phrase data. |
| `Reference_Mismatch` | Stored module fingerprint differs from supplied/bound reference. |

Common issues:

- **Output differs or decoding reports mismatch:** store the exact shared
  reference with the archive and verify its bytes before deserialization.
- **`deserialize` rejects the whole archive:** it accepts one module only.
  Slice by an outer directory offset and size first.
- **An archive index is invalid:** never cast an untrusted `u64` offset to `int`
  before proving it is within the buffer.
- **Repeated allocation is slow:** reuse one `Encoder` and, for GPU, one OpenGL
  context and resident reference.
- **Compression is worse than expected:** count reference bytes plus all payloads,
  try all four formats on representative data, and consider `max_size` or
  `.Automatic`.
- **Automatic reference construction is slow:** it scores all four formats on
  all inputs and builds four nonempty candidates. Choose a deterministic strategy.
- **OpenGL fails:** require OpenGL 4.5 compute, persistent coherent buffer
  mapping, a same-thread hidden context, and driver support. Vulkan is not a
  substitute backend until an application implements one.

## Performance, Benchmarks, and Design Findings

Run the package tests, examples, and benchmark from the repository root:

```text
odin test compress\rlz -vet -warnings-as-errors
odin run compress\rlz\examples\basic.odin -file -vet -warnings-as-errors
odin run compress\rlz\examples\archive.odin -file -vet -warnings-as-errors
odin run compress\rlz\bench\main.odin -file
```

Tests cover all formats, empty references/targets, arbitrary binary values,
isolated mutations, repeated/random data, reusable encoders, serialization,
random-access ranges, malformed/truncated streams, reference mismatch,
decompression limits, deterministic/custom-allocator reference construction,
and CPU scalar/SIMD equivalence.

The benchmark:

- constructs references for small, medium, and large low/high-similarity
  datasets;
- compares concatenation, representative sampling, frequent substrings,
  coverage optimization, and automatic selection;
- reports build time, reference/payload/combined size, ratio, phrase count,
  average match length, and tracked peak construction memory;
- runs CPU decode medians/p95/averages;
- runs standalone OpenGL cold, warm, and GPU timestamp samples;
- checks every GPU sample byte-for-byte against CPU.

OpenGL measurements separate:

- **cold:** context creation, shader compilation, allocation, upload, dispatch,
  synchronization, and readback;
- **warm:** retained context/program/reference/buffers while still uploading
  per-module data, dispatching, synchronizing, and reading output;
- **kernel-only:** paired OpenGL timestamp queries around dispatch.

### CPU decoder findings

The CPU decoder supports Odin's `#simd[16]u8`/`core:simd` model and keeps a
portable scalar path. On the benchmark development host, scalar `copy` matched
or outperformed explicit vector loads for the short phrases typical of this
codec. The production default therefore remains scalar; `decode_cpu_simd` exists
for comparison and future profiling.

### Illustrative OpenGL findings

Measurements on one development host for a 128 KiB output were approximately:

- cold OpenGL: 35 ms;
- warm OpenGL: 0.35-0.38 ms median;
- GPU kernel: 0.062 ms;
- scalar CPU: 0.40-0.42 ms.

These are not thresholds or predictions for another driver/GPU. The warm path
uses persistent coherent SSBO mappings, reusable query objects, a resident
reference buffer, cached packed literals, and no `glFinish`. Upload/readback
were about 0.007 ms each on that host, while synchronization remained about
0.24 ms and metadata preparation about 0.09-0.11 ms.

For minimum GPU overhead:

1. keep one OpenGL context on one thread;
2. upload the shared reference once;
3. reuse retained phrase/literal/output capacities;
4. batch independent jobs when practical;
5. leave output GPU-resident if a next GPU consumer is available;
6. prefer CPU for small synchronous requests.

Vulkan is not benchmarked because the package provides no runnable Vulkan
provider. OpenGL measurements make no claim about Vulkan.
