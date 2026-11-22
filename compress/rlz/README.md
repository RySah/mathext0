# Relative Lempel-Ziv for Odin

A general-purpose binary codec with four CPU formats:

- classical `RLZ`
- GDC copy phrases followed by mismatch literals
- `GDC_Relative`, with signed, run-compressed displacements
- `RLZAP`, with explicit and bounded adaptive pointer deltas

The package accepts arbitrary `[]u8` data. It does not depend on an application,
engine, asset type, texture, mesh, or archive format.

## CPU use

```odin
reference := []u8{'A','B','C','D','E','F','G','H'}
input     := []u8{'A','B','C','X','E','F'}

module, err := rlz.encode_format(reference, input, .RLZAP)
if err != .None { return }
defer rlz.module_destroy(&module)

output := make([]u8, len(input))
defer delete(output)

decoder := rlz.cpu_decoder()
err = rlz.decode(&decoder, reference, &module, output)
```

`decode_cpu` and `decode_range` copy into caller-owned output and do not allocate.
`decoder_create(reference)` binds and fingerprints a reference once, avoiding a
full reference hash on each decode:

```odin
decoder := rlz.decoder_create(reference)
defer rlz.decoder_destroy(&decoder)
err := rlz.decode_into(&decoder, reference, &module, output)
```

Independent decoder values may be used concurrently. A single mutable decoder
value must not be shared concurrently. Modules, references and reference indices
are immutable during encoding/decoding and may be shared.

## Reusing a reference index

`Encoder` owns a suffix-array reference index. Construct it once when encoding
multiple independent targets:

```odin
options := rlz.DEFAULT_OPTIONS
options.format = .GDC_Relative
encoder := rlz.encoder_create(reference, options)
defer rlz.encoder_destroy(&encoder)

first, first_err := rlz.encode_indexed(&encoder, input_a)
second, second_err := rlz.encode_indexed(&encoder, input_b)
defer rlz.module_destroy(&first)
defer rlz.module_destroy(&second)
```

The encoder borrows the immutable reference. The decoder does not require the
index.

## Random access and serialization

Every phrase records its output offset. Range extraction uses binary search to
locate the starting phrase and copies only the requested bytes:

```odin
part := make([]u8, 4)
err := rlz.decode_range(&decoder, reference, &module, 12, 4, part)
```

`serialize` produces a portable, versioned little-order varint stream containing
codec identity, decoded size, reference fingerprint, phrases and literals.
Pointers use ULEB128 and ZigZag encoding for signed relative values. Repeated
GDC-relative displacements are run-compressed.

```odin
archive, err := rlz.serialize(&module)
defer delete(archive)

restored, err2 := rlz.deserialize(archive, reference,
    rlz.Deserialize_Options{maximum_output = 64*1024*1024})
defer rlz.module_destroy(&restored)
```

Malformed varints, unknown versions/formats, overflow, excessive declarations,
truncation, invalid source ranges, and reference mismatches return errors.
`serialize` does not serialize Odin struct layout.

## GPU boundary

The package keeps `Format` and `Backend` separate.

`gpu_decoder(callback, user_data)` installs a caller-owned synchronous provider.
The callback must upload, submit, synchronize and read the result into the
caller's output before returning. Vulkan and OpenGL requests never silently
fall back to CPU.

`opengl_decoder_create` creates a hidden OpenGL 4.5 core compute context through
GLFW. `opengl_gpu_decoder` adapts it to the standard decode API:

```odin
gpu, err := rlz.opengl_decoder_create()
if err != .None { return }
defer rlz.opengl_decoder_destroy(&gpu)

decoder := rlz.opengl_gpu_decoder(&gpu)
err = rlz.decode(&decoder, reference, &module, output)
```

The standalone OpenGL backend owns its GLFW initialization, hidden window,
compute program and storage buffers. Contexts are thread-affine; use a context
only from the thread that owns it. A host must not use this lifecycle procedure
when integrating with an application-owned OpenGL context.

`gpu_vulkan.odin` provides a low-level recorder for an externally managed Vulkan
pipeline and descriptor set. `shaders/decode.comp.glsl` decodes the normalized
phrase representation for all four formats. Each invocation owns one output
word, so unaligned phrase boundaries cannot race on a 32-bit storage word.

The library does not currently create Vulkan devices, queues, buffers, SPIR-V
pipelines or fences. Callers using the
Vulkan recorder must provide validated, CPU/GPU-visible buffers and own resource
lifetime, queue selection, barriers, submission and readback. Consequently the
benchmark measures runnable OpenGL compute but reports Vulkan as unavailable
rather than measuring command recording.

Build the shader with:

```text
glslangValidator -V -S comp shaders/decode.comp.glsl -o shaders/decode.comp.spv
```

The shader buffer bindings are:

1. binding 0: packed reference words
2. binding 1: packed literal words
3. binding 2: 16-byte phrases
4. binding 3: packed output words

A 4-byte push constant contains the decoded size.

## Correctness and tests

Run:

```text
odin test compress\rlz -vet -warnings-as-errors
odin run compress\rlz\examples\basic.odin -file
odin run compress\rlz\bench\main.odin -file
```

Tests cover all formats, empty references/targets, all binary byte values,
isolated changes, long/repeated/random data, reusable encoders, serialization
round trips, subranges, reference mismatch, malformed/truncated streams and
decompression limits.

The benchmark covers CPU decoding and standalone OpenGL compute for every
format and reports median, p95 and average latency:

- **Cold GPU** creates a new OpenGL context, compiles the shader, allocates
  buffers, uploads all data, dispatches, synchronizes and reads back.
- **Warm GPU** reuses the context, compute program, reference buffer and allocated
  phrase/literal/output storage. It still measures uploads, dispatch,
  synchronization and readback.
- **Kernel-only** uses paired OpenGL `TIMESTAMP` queries around dispatch. The
  reported value comes from the GPU clock rather than CPU wall-clock timing.

The shared reference is uploaded once for the warm/kernel run and reused across
all four formats. Every sampled GPU result is checked byte-for-byte against CPU.
CPU timing and existing encoding, phrase-count, payload and ratio reporting are
preserved. Vulkan is not assigned a timing value until a complete provider
exists.

## CPU SIMD and performance findings

The CPU decoder follows the SIMD model documented by Odin's
[SIMD vector types](https://odin-lang.org/docs/overview/#simd-vector-types):
`#simd[N]T`, `core:simd`, compile-time `when simd.HAS_HARDWARE_SIMD`, and unaligned
16-byte loads/stores. A portable scalar path is retained. `decode_cpu_scalar`
and `decode_cpu_simd` are available for correctness and performance comparison.

On the benchmark host, scalar `copy` matched or outperformed explicit SIMD for
the short RLZ phrases, while explicit 16-byte loads added dispatch overhead.
The production CPU default therefore remains scalar; SIMD is not retained as the
default merely because it is available. Both paths are byte-identical. The main
CPU gain came from removing duplicate stream validation and repeated reference
fingerprinting from the unified decode path.

## Warm GPU profiling and integration

`opengl_decode_profiled` separates CPU validation/metadata preparation, mapped
uploads, dispatch submission, GPU synchronization, mapped readback, and GPU
`TIME_ELAPSED` query duration. The benchmark reports all of these plus median,
p95, average, throughput and retained GPU capacity.

Measured on the development host for a 128 KiB output:

- Cold OpenGL: about 35 ms
- Warm OpenGL: about 0.35-0.38 ms median
- GPU kernel: about 0.062 ms
- Scalar CPU: about 0.40-0.42 ms

These are illustrative host-driver measurements, not universal thresholds.
Persistent coherent SSBO mappings, reusable query objects, a resident reference
buffer, cached packed-literal storage, and removal of `glFinish` produced the
warm improvement. Upload and readback were approximately 0.007 ms each;
synchronization remained about 0.24 ms, while metadata preparation remained
visible at about 0.09-0.11 ms. Persistent maps required OpenGL `BufferStorage`.

For minimum GPU overhead:

1. Keep one OpenGL context and decoder on one thread; do not recreate it per item.
2. Upload the shared reference once with `opengl_prepare_reference`.
3. Reuse a decoder across targets so phrase, literal and output capacity persists.
4. Batch independent jobs when possible and synchronize only after the batch.
5. Keep output GPU-resident when the next consumer supports it; synchronous CPU
   readback necessarily waits for command completion.
6. Prefer CPU for small inputs on latency-sensitive paths.

The current synchronous benchmark must wait for CPU-visible output, so it still
cannot eliminate synchronization. No Vulkan behavior is claimed from OpenGL
measurements; the Vulkan adapter remains caller-resource-oriented and preserves
its low-level command recorder.

## Data and ownership

- `encode` and `encode_indexed` allocate and return a Module; call
  `module_destroy`.
- `serialize` returns owned bytes; delete them after use.
- references are borrowed and must remain immutable and alive.
- CPU whole-buffer and range decoding allocate nothing in their hot path.
- phrase and literal arrays use the requested allocator.
- all offsets and lengths are byte-based; the in-memory output limit is 32 bits.
