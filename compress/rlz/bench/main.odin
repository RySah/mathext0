package main

import "core:fmt"
import "core:mem"
import "core:time"
import rlz "../"

CPU_ITERATIONS :: 50
WARM_ITERATIONS :: 30
COLD_ITERATIONS :: 5

Statistics :: struct {
    average: f64,
    median: f64,
    p95: f64,
}

Benchmark_Item :: struct {
    format: rlz.Format,
    module: rlz.Module,
    expected: []u8,
    encode_ms: f64,
    payload: int,
    ratio: f64,
}

Reference_Dataset :: struct {
    name:   string,
    storage: [dynamic][]u8,
}

reference_dataset :: proc(name: string, input_count, input_size, similarity: int) -> Reference_Dataset {
    dataset := Reference_Dataset{
        name = name,
        storage = make([dynamic][]u8, 0, input_count),
    }
    base := make([]u8, input_size)
    defer delete(base)
    state: u32 = 0x9e3779b9
    for i in 0..<input_size {
        state = state*1664525+1013904223
        base[i] = u8(state >> 24)
    }
    for input_index in 0..<input_count {
        input := make([]u8, input_size)
        for i in 0..<input_size {
            state = state*1664525+1013904223
            if int((state >> 24)) < similarity {
                input[i] = base[(i+input_index*37) % input_size]
            } else {
                input[i] = u8(state >> 16)
            }
        }
        append(&dataset.storage, input)
    }
    return dataset
}

reference_dataset_destroy :: proc(dataset: ^Reference_Dataset) {
    if dataset == nil { return }
    for input in dataset.storage { delete(input) }
    delete(dataset.storage)
    dataset^ = {}
}

concatenated_reference :: proc(inputs: [][]u8, maximum_size: int, allocator: mem.Allocator) -> []u8 {
    reference := make([dynamic]u8, 0, maximum_size, allocator)
    for input in inputs {
        remaining := maximum_size-len(reference)
        if remaining <= 0 { break }
        append(&reference, ..input[:min(len(input), remaining)])
    }
    return reference[:]
}

benchmark_reference_strategy :: proc(
    name, dataset_name: string,
    inputs: [][]u8,
    maximum_size: int,
    strategy: rlz.Reference_Strategy,
) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    tracked := mem.tracking_allocator(&track)

    start := time.tick_now()
    reference: []u8
    err: rlz.Error
    if strategy == .Automatic && name == "concatenation" {
        reference = concatenated_reference(inputs, maximum_size, tracked)
    } else {
        reference, err = rlz.reference_build(inputs, rlz.Reference_Options{
            max_size = maximum_size,
            strategy = strategy,
        }, tracked)
    }
    build_ms := time.duration_milliseconds(time.tick_since(start))
    peak := track.peak_memory_allocated
    if err != .None {
        fmt.printf("%-13s %-19s construction failed: %v\n", dataset_name, name, err)
        mem.tracking_allocator_destroy(&track)
        return
    }

    encoder := rlz.encoder_create(reference, rlz.default_options(.GDC_Relative))
    payload_size := 0
    phrase_count := 0
    matched_bytes: i64
    reference_phrases: i64
    input_bytes := 0
    for input in inputs {
        input_bytes += len(input)
        module, encode_err := rlz.encode_indexed(&encoder, input)
        if encode_err != .None {
            fmt.printf("%-13s %-19s encoding failed: %v\n", dataset_name, name, encode_err)
            rlz.module_destroy(&module)
            rlz.encoder_destroy(&encoder)
            delete(reference, tracked)
            mem.tracking_allocator_destroy(&track)
            return
        }
        serialized, size_err := rlz.serialize(&module)
        if size_err != .None {
            fmt.printf("%-13s %-19s sizing failed: %v\n", dataset_name, name, size_err)
        } else {
            payload_size += len(serialized)
        }
        delete(serialized)
        phrase_count += len(module.phrases)
        for phrase in module.phrases {
            if phrase.kind != .Literal {
                reference_phrases += 1
                matched_bytes += i64(phrase.length)
            }
        }
        rlz.module_destroy(&module)
    }
    combined := len(reference)+payload_size
    ratio := f64(combined)/f64(max(1, input_bytes))
    average_match := 0.0
    if reference_phrases > 0 { average_match = f64(matched_bytes)/f64(reference_phrases) }
    fmt.printf(
        "%-13s %-19s build=%9.3f ms reference=%7d payload=%9d combined=%9d ratio=%.4f phrases=%7d avg_match=%.2f peak=%d B\n",
        dataset_name, name, build_ms, len(reference), payload_size, combined,
        ratio, phrase_count, average_match, peak)

    rlz.encoder_destroy(&encoder)
    delete(reference, tracked)
    mem.tracking_allocator_destroy(&track)
}

benchmark_reference_builders :: proc() {
    datasets := make([dynamic]Reference_Dataset, 0, 6)
    defer {
        for i in 0..<len(datasets) { reference_dataset_destroy(&datasets[i]) }
        delete(datasets)
    }
    append(&datasets, reference_dataset("small/high", 6, 4*1024, 240))
    append(&datasets, reference_dataset("small/low", 6, 4*1024, 8))
    append(&datasets, reference_dataset("medium/high", 6, 16*1024, 208))
    append(&datasets, reference_dataset("medium/low", 6, 16*1024, 24))
    append(&datasets, reference_dataset("large/high", 4, 64*1024, 192))
    append(&datasets, reference_dataset("large/low", 4, 64*1024, 16))

    fmt.println("Reference construction (GDC_Relative payload metrics)")
    for dataset in datasets {
        maximum_size := min(16*1024, len(dataset.storage[0])/2)
        benchmark_reference_strategy("concatenation", dataset.name, dataset.storage[:], maximum_size, .Automatic)
        benchmark_reference_strategy("sampling", dataset.name, dataset.storage[:], maximum_size, .Representative_Sampling)
        benchmark_reference_strategy("frequent", dataset.name, dataset.storage[:], maximum_size, .Frequent_Substrings)
        benchmark_reference_strategy("coverage", dataset.name, dataset.storage[:], maximum_size, .Coverage_Optimized)
        benchmark_reference_strategy("automatic", dataset.name, dataset.storage[:], maximum_size, .Automatic)
    }
    fmt.println()
}

input_of :: proc() -> ([dynamic]u8, [dynamic]u8) {
    reference := make([dynamic]u8, 0, 256*1024)
    input := make([dynamic]u8, 0, 128*1024)
    state: u32 = 0xc0ffee11
    for _ in 0..<256*1024 {
        state = state*1664525+1013904223
        append(&reference, u8(state >> 24))
    }
    for i in 0..<128*1024 {
        if i%32 == 0 {
            append(&input, u8(i&255))
        } else {
            append(&input, reference[i+173])
        }
    }
    return reference, input
}

statistics :: proc(samples: []f64) -> Statistics {
    if len(samples) == 0 { return {} }
    sorted := make([]f64, len(samples))
    defer delete(sorted)
    copy(sorted, samples)
    for i in 1..<len(sorted) {
        value := sorted[i]
        j := i
        for j > 0 && sorted[j-1] > value {
            sorted[j] = sorted[j-1]
            j -= 1
        }
        sorted[j] = value
    }
    sum := 0.0
    for sample in sorted { sum += sample }
    middle := len(sorted)/2
    median := sorted[middle]
    if len(sorted)%2 == 0 {
        median = (sorted[middle-1]+sorted[middle])/2
    }
    p95_index := (len(sorted)*95+99)/100-1
    return Statistics{average = sum/f64(len(sorted)), median = median,
        p95 = sorted[min(p95_index, len(sorted)-1)]}
}

same_bytes :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) { return false }
    for i in 0..<len(a) {
        if a[i] != b[i] { return false }
    }
    return true
}

report :: proc(name: string, values: []f64, byte_count: int) {
    stats := statistics(values)
    throughput := 0.0
    if stats.median > 0 {
        throughput = f64(byte_count)/stats.median/1000.0
    }
    fmt.printf("%-15s median=%9.4f ms p95=%9.4f ms average=%9.4f ms throughput=%9.1f MB/s\n",
        name, stats.median, stats.p95, stats.average, throughput)
}

benchmark_cpu_mode :: proc(name: string, simd_enabled: bool, reference: []u8,
    module: ^rlz.Module, expected: []u8,
) -> bool {
    output := make([]u8, int(module.output_size))
    defer delete(output)
    samples := make([]f64, CPU_ITERATIONS)
    defer delete(samples)
    for i in 0..<CPU_ITERATIONS {
        start := time.tick_now()
        err: rlz.Error
        if simd_enabled {
            err = rlz.decode_cpu_simd(reference, module, output)
        } else {
            err = rlz.decode_cpu_scalar(reference, module, output)
        }
        samples[i] = time.duration_milliseconds(time.tick_since(start))
        if err != .None || !same_bytes(output, expected) {
            fmt.println("CPU verification failed")
            return false
        }
    }
    report(name, samples, len(output))
    return true
}

benchmark_cold :: proc(reference: []u8, module: ^rlz.Module, expected: []u8) -> bool {
    samples := make([]f64, COLD_ITERATIONS)
    defer delete(samples)
    output := make([]u8, int(module.output_size))
    defer delete(output)
    for i in 0..<COLD_ITERATIONS {
        start := time.tick_now()
        gpu_context, err := rlz.opengl_decoder_create()
        if err == .None {
            _, err = rlz.opengl_decode_timed(&gpu_context, reference, module, output)
        }
        samples[i] = time.duration_milliseconds(time.tick_since(start))
        rlz.opengl_decoder_destroy(&gpu_context)
        if err != .None {
            fmt.println("Cold GPU unavailable or failed:", err)
            return false
        }
        if !same_bytes(output, expected) {
            fmt.println("Cold GPU output mismatch")
            return false
        }
    }
    report("Cold GPU", samples, int(module.output_size))
    return true
}

benchmark_warm :: proc(ctx: ^rlz.OpenGL_Context, reference: []u8,
    module: ^rlz.Module, expected: []u8,
) -> bool {
    output := make([]u8, int(module.output_size))
    defer delete(output)
    // Allocate/update all per-module buffers before collecting warm samples.
    _, err := rlz.opengl_decode_timed(ctx, reference, module, output)
    if err != .None || !same_bytes(output, expected) {
        fmt.println("Warm GPU setup failed:", err)
        return false
    }

    warm_samples := make([]f64, WARM_ITERATIONS)
    kernel_samples := make([]f64, WARM_ITERATIONS)
    prepare_samples := make([]f64, WARM_ITERATIONS)
    upload_samples := make([]f64, WARM_ITERATIONS)
    dispatch_samples := make([]f64, WARM_ITERATIONS)
    synchronisation_samples := make([]f64, WARM_ITERATIONS)
    readback_samples := make([]f64, WARM_ITERATIONS)
    defer delete(warm_samples)
    defer delete(kernel_samples)
    defer delete(prepare_samples)
    defer delete(upload_samples)
    defer delete(dispatch_samples)
    defer delete(synchronisation_samples)
    defer delete(readback_samples)
    for i in 0..<WARM_ITERATIONS {
        start := time.tick_now()
        profile, decode_err := rlz.opengl_decode_profiled(ctx, reference, module, output)
        warm_samples[i] = time.duration_milliseconds(time.tick_since(start))
        kernel_samples[i] = f64(profile.kernel_ns)/1e6
        prepare_samples[i] = f64(profile.validation_ns+profile.literal_prepare_ns)/1e6
        upload_samples[i] = f64(profile.upload_ns)/1e6
        dispatch_samples[i] = f64(profile.dispatch_ns)/1e6
        synchronisation_samples[i] = f64(profile.synchronisation_ns)/1e6
        readback_samples[i] = f64(profile.readback_ns)/1e6
        if decode_err != .None || !same_bytes(output, expected) {
            fmt.println("Warm GPU decode or verification failed:", decode_err)
            return false
        }
    }
    report("Warm GPU", warm_samples, int(module.output_size))
    report("Kernel-only", kernel_samples, int(module.output_size))
    report("GPU prepare", prepare_samples, int(module.output_size))
    report("GPU upload", upload_samples, int(module.output_size))
    report("GPU dispatch", dispatch_samples, int(module.output_size))
    report("GPU sync", synchronisation_samples, int(module.output_size))
    report("GPU readback", readback_samples, int(module.output_size))
    fmt.printf("GPU allocations: %d bytes\n", rlz.opengl_allocated_bytes(ctx))
    return true
}

main :: proc() {
    benchmark_reference_builders()

    reference_dynamic, input_dynamic := input_of()
    defer delete(reference_dynamic)
    defer delete(input_dynamic)
    reference, input := reference_dynamic[:], input_dynamic[:]
    fmt.printf("Iterations: CPU=%d cold=%d warm/kernel=%d\n",
        CPU_ITERATIONS, COLD_ITERATIONS, WARM_ITERATIONS)
    fmt.println("# Vulkan is not benchmarked: gpu_vulkan.odin is a recorder only and has no runnable provider.")

    items := make([dynamic]Benchmark_Item, 0, 4)
    defer {
        for i in 0..<len(items) {
            item := &items[i]
            rlz.module_destroy(&item.module)
            delete(item.expected)
        }
        delete(items)
    }

    for format in rlz.Format.RLZ..=rlz.Format.RLZAP {
        encode_start := time.tick_now()
        module, err := rlz.encode_format(reference, input, format)
        if err != .None {
            fmt.println(format, err)
            continue
        }
        encode_ms := time.duration_milliseconds(time.tick_since(encode_start))
        archive, serial_err := rlz.serialize(&module)
        ratio := -1.0
        payload := 0
        if serial_err == .None {
            payload = len(archive)
            ratio = f64(payload)/f64(len(input))
        }

        expected := make([]u8, len(input))
        decoder := rlz.cpu_decoder()
        if rlz.decode(&decoder, reference, &module, expected) != .None {
            fmt.println("CPU reference decode failed")
            delete(expected)
            rlz.module_destroy(&module)
            continue
        }
        append(&items, Benchmark_Item{
            format = format,
            module = module,
            expected = expected,
            encode_ms = encode_ms,
            payload = payload,
            ratio = ratio,
        })
        delete(archive)
    }

    fmt.println("\nCPU compression and decode")
    for i in 0..<len(items) {
        item := &items[i]
        fmt.printf("\n%v encode=%.3f ms phrases=%d payload=%d ratio=%.4f\n",
            item.format, item.encode_ms, len(item.module.phrases),
            item.payload, item.ratio)
        cpu_memory := len(item.module.phrases)*size_of(rlz.Phrase) +
            len(item.module.literals)+int(item.module.output_size)
        fmt.printf("CPU working memory: %d bytes (metadata, literals, output)\n", cpu_memory)
        benchmark_cpu_mode("CPU scalar", false, reference, &item.module, item.expected)
        benchmark_cpu_mode("CPU SIMD", true, reference, &item.module, item.expected)
    }

    fmt.println("\nWarm GPU and GPU timestamp kernel-only")
    warm_context, warm_err := rlz.opengl_decoder_create()
    if warm_err != .None {
        fmt.println("OpenGL benchmark unavailable:", warm_err)
    } else {
        // Upload the common reference exactly once for all warm/kernel formats.
        warm_err = rlz.opengl_prepare_reference(&warm_context, reference)
        if warm_err != .None {
            fmt.println("OpenGL reference upload failed:", warm_err)
        }
        for i in 0..<len(items) {
            item := &items[i]
            fmt.println("\n", item.format)
            if warm_err == .None {
                benchmark_warm(&warm_context, reference, &item.module, item.expected)
            }
        }
        rlz.opengl_decoder_destroy(&warm_context)
    }

    fmt.println("\nCold GPU (new context each sample)")
    for i in 0..<len(items) {
        item := &items[i]
        fmt.println("\n", item.format)
        benchmark_cold(reference, &item.module, item.expected)
    }
}
