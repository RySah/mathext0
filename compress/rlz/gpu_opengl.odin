package rlz

import "core:mem"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"

OpenGL_Context :: struct {
    window: glfw.WindowHandle,
    program: u32,
    reference_buffer: u32,
    literal_buffer: u32,
    phrase_buffer: u32,
    output_buffer: u32,
    output_uniform: i32,
    reference_id: u64,
    reference_bytes: int,
    literal_capacity: int,
    phrase_capacity: int,
    output_capacity: int,
    literal_words: [dynamic]u32,
    literal_mapping: rawptr,
    phrase_mapping: rawptr,
    output_mapping: rawptr,
    query_ids: [2]u32,
    owns_glfw: bool,
}

OpenGL_Profile :: struct {
    validation_ns: int,
    literal_prepare_ns: int,
    upload_ns: int,
    dispatch_ns: int,
    synchronisation_ns: int,
    readback_ns: int,
    kernel_ns: u64,
}

OPENGL_COMPUTE_SHADER :: `
#version 450 core
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(std430, binding = 0) readonly buffer Reference { uint words[]; } ref_data;
layout(std430, binding = 1) readonly buffer Literals  { uint words[]; } literal_data;
struct Phrase { uint output_offset; uint source_offset; uint length; uint kind; };
layout(std430, binding = 2) readonly buffer Phrases { Phrase items[]; } phrases;
layout(std430, binding = 3) writeonly buffer Output { uint words[]; } decoded;
uniform uint output_size;

uint get_byte(uint base, uint kind) {
    uint word = kind != 1u
        ? ref_data.words[base >> 2u]
        : literal_data.words[base >> 2u];
    return (word >> ((base & 3u) * 8u)) & 255u;
}

uint byte_at(uint position) {
    uint lo = 0u;
    uint hi = phrases.items.length();
    while (lo < hi) {
        uint mid = lo + (hi-lo)/2u;
        if (phrases.items[mid].output_offset <= position) lo = mid + 1u;
        else hi = mid;
    }
    Phrase p = phrases.items[lo-1u];
    return get_byte(p.source_offset + position - p.output_offset, p.kind);
}

void main() {
    uint start = gl_GlobalInvocationID.x * 4u;
    if (start >= output_size) return;
    uint assembled = 0u;
    for (uint b = 0u; b < 4u; ++b) {
        uint at = start + b;
        if (at < output_size) assembled |= byte_at(at) << (b*8u);
    }
    decoded.words[gl_GlobalInvocationID.x] = assembled;
}
`

opengl_decoder_create :: proc() -> (ctx: OpenGL_Context, err: Error) {
    if !glfw.Init() { return {}, .Unsupported_Backend }
    ctx.owns_glfw = true
    glfw.DefaultWindowHints()
    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    glfw.WindowHint(glfw.VISIBLE, false)
    ctx.window = glfw.CreateWindow(1, 1, "RLZ compute", nil, nil)
    if ctx.window == nil {
        glfw.Terminate()
        return {}, .Unsupported_Backend
    }
    glfw.MakeContextCurrent(ctx.window)
    gl.load_up_to(4, 5, glfw.gl_set_proc_address)
    program, ok := gl.load_compute_source(OPENGL_COMPUTE_SHADER)
    if !ok {
        glfw.DestroyWindow(ctx.window)
        glfw.Terminate()
        return {}, .Backend_Failed
    }
    ctx.program = program
    buffers := [4]u32{}
    gl.GenBuffers(4, &buffers[0])
    ctx.reference_buffer = buffers[0]
    ctx.literal_buffer = buffers[1]
    ctx.phrase_buffer = buffers[2]
    ctx.output_buffer = buffers[3]
    ctx.output_uniform = gl.GetUniformLocation(ctx.program, "output_size")
    gl.GenQueries(2, &ctx.query_ids[0])
    if gl.GetError() != gl.NO_ERROR || ctx.output_uniform < 0 {
        opengl_decoder_destroy(&ctx)
        return {}, .Backend_Failed
    }
    return ctx, .None
}

opengl_decoder_destroy :: proc(ctx: ^OpenGL_Context) {
    if ctx == nil { return }
    if ctx.window != nil {
        glfw.MakeContextCurrent(ctx.window)
        buffers := [4]u32{
            ctx.reference_buffer, ctx.literal_buffer,
            ctx.phrase_buffer, ctx.output_buffer,
        }
        gl.DeleteBuffers(4, &buffers[0])
        gl.DeleteQueries(2, &ctx.query_ids[0])
        if ctx.program != 0 { gl.DeleteProgram(ctx.program) }
        glfw.MakeContextCurrent(nil)
        glfw.DestroyWindow(ctx.window)
    }
    if ctx.owns_glfw { glfw.Terminate() }
    delete(ctx.literal_words)
    ctx^ = {}
}

opengl_prepare_reference :: proc(ctx: ^OpenGL_Context, reference: []u8) -> Error {
    if ctx == nil || ctx.window == nil { return .Invalid_Argument }
    id := reference_id(reference)
    if ctx.reference_id == id && ctx.reference_bytes == len(reference) {
        return .None
    }
    reference_words := pack_bytes(reference)
    defer delete(reference_words)
    glfw.MakeContextCurrent(ctx.window)
    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ctx.reference_buffer)
    size := max(4, len(reference_words)*size_of(u32))
    gl.BufferData(gl.SHADER_STORAGE_BUFFER, size, raw_data(reference_words), gl.STATIC_DRAW)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, ctx.reference_buffer)
    if gl.GetError() != gl.NO_ERROR { return .Backend_Failed }
    ctx.reference_id = id
    ctx.reference_bytes = len(reference)
    return .None
}

opengl_map_storage :: proc(id: ^u32, binding: u32, size: int,
    capacity: ^int, mapping: ^rawptr, access: u32,
) -> Error {
    if size > capacity^ {
        if id^ != 0 {
            gl.DeleteBuffers(1, id)
        }
        gl.GenBuffers(1, id)
        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, id^)
        flags := access | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT
        gl.BufferStorage(gl.SHADER_STORAGE_BUFFER, size, nil, flags)
        capacity^ = size
        mapping^ = gl.MapBufferRange(gl.SHADER_STORAGE_BUFFER, 0, size,
            access | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
        if mapping^ == nil { return .Backend_Failed }
    } else {
        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, id^)
    }
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, binding, id^)
    if gl.GetError() != gl.NO_ERROR { return .Backend_Failed }
    return .None
}

// Reuses every GPU allocation once capacity is sufficient. literal and phrase
// data are per module, while reference remains resident until the reference
// fingerprint changes. Persistent coherent maps eliminate transfer allocation,
// map/unmap calls and glBufferSubData from the steady-state path.
opengl_decode_profiled :: proc(ctx: ^OpenGL_Context, reference: []u8, m: ^Module, output: []u8) -> (profile: OpenGL_Profile, err: Error) {
    if ctx == nil || ctx.window == nil || m == nil { return {}, .Invalid_Argument }
    if len(output) < int(m.output_size) { return {}, .Output_Too_Small }
    validation_start := time.tick_now()
    if ctx.reference_id != m.reference_id || ctx.reference_bytes != len(reference) {
        err = opengl_prepare_reference(ctx, reference)
        if err != .None { return {}, err }
    }
    if m.reference_id != ctx.reference_id || !validate_without_reference(m, reference) {
        return {}, .Invalid_Stream
    }
    profile.validation_ns = int(time.duration_nanoseconds(time.tick_since(validation_start)))
    if m.output_size == 0 { return profile, .None }

    literal_start := time.tick_now()
    glfw.MakeContextCurrent(ctx.window)
    literal_word_count := (len(m.literals)+3)/4
    if cap(ctx.literal_words) < literal_word_count {
        reserve(&ctx.literal_words, literal_word_count)
    }
    resize(&ctx.literal_words, literal_word_count)
    when ODIN_ENDIAN == .Little {
        if literal_word_count > 0 {
            ctx.literal_words[literal_word_count-1] = 0
            mem.copy(raw_data(ctx.literal_words), raw_data(m.literals), len(m.literals))
        }
    } else {
        for i in 0..<literal_word_count { ctx.literal_words[i] = 0 }
        for i in 0..<len(m.literals) {
            ctx.literal_words[i/4] |= u32(m.literals[i]) << u32((i%4)*8)
        }
    }
    profile.literal_prepare_ns = int(time.duration_nanoseconds(time.tick_since(literal_start)))

    upload_start := time.tick_now()
    word_count := (int(m.output_size)+3)/4
    output_words := word_count*4
    literal_bytes := max(4, literal_word_count*size_of(u32))
    phrase_bytes := max(4, len(m.phrases)*size_of(Phrase))
    output_bytes := max(4, output_words)
    err = opengl_map_storage(&ctx.literal_buffer, 1, literal_bytes,
        &ctx.literal_capacity, &ctx.literal_mapping, gl.MAP_WRITE_BIT)
    if err != .None { return {}, err }
    err = opengl_map_storage(&ctx.phrase_buffer, 2, phrase_bytes,
        &ctx.phrase_capacity, &ctx.phrase_mapping, gl.MAP_WRITE_BIT)
    if err != .None { return {}, err }
    err = opengl_map_storage(&ctx.output_buffer, 3, output_bytes,
        &ctx.output_capacity, &ctx.output_mapping, gl.MAP_READ_BIT)
    if err != .None { return {}, err }
    if literal_word_count > 0 {
        mem.copy(ctx.literal_mapping, raw_data(ctx.literal_words), literal_word_count*size_of(u32))
    }
    mem.copy(ctx.phrase_mapping, raw_data(m.phrases), len(m.phrases)*size_of(Phrase))
    profile.upload_ns = int(time.duration_nanoseconds(time.tick_since(upload_start)))

    groups := (word_count+63)/64
    max_groups: [3]i32
    gl.GetIntegeri_v(gl.MAX_COMPUTE_WORK_GROUP_COUNT, 0, &max_groups[0])
    if groups > int(max_groups[0]) {
        return {}, .Limit_Exceeded
    }

    dispatch_start := time.tick_now()
    gl.UseProgram(ctx.program)
    gl.Uniform1ui(ctx.output_uniform, m.output_size)
    gl.BeginQuery(gl.TIME_ELAPSED, ctx.query_ids[0])
    gl.DispatchCompute(u32(groups), 1, 1)
    gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)
    gl.EndQuery(gl.TIME_ELAPSED)
    profile.dispatch_ns = int(time.duration_nanoseconds(time.tick_since(dispatch_start)))

    synchronisation_start := time.tick_now()
    elapsed: u64
    gl.GetQueryObjectui64v(ctx.query_ids[0], gl.QUERY_RESULT, &elapsed)
    profile.synchronisation_ns = int(time.duration_nanoseconds(time.tick_since(synchronisation_start)))
    if gl.GetError() != gl.NO_ERROR {
        return {}, .Backend_Failed
    }
    profile.kernel_ns = elapsed

    readback_start := time.tick_now()
    mem.copy(raw_data(output), ctx.output_mapping, int(m.output_size))
    profile.readback_ns = int(time.duration_nanoseconds(time.tick_since(readback_start)))
    if gl.GetError() != gl.NO_ERROR { return {}, .Backend_Failed }
    return profile, .None
}

opengl_decode_timed :: proc(ctx: ^OpenGL_Context, reference: []u8, m: ^Module, output: []u8) -> (gpu_kernel_ns: u64, err: Error) {
    profile, profile_err := opengl_decode_profiled(ctx, reference, m, output)
    return profile.kernel_ns, profile_err
}

opengl_decode :: proc(ctx: ^OpenGL_Context, reference: []u8, m: ^Module, output: []u8) -> Error {
    _, err := opengl_decode_timed(ctx, reference, m, output)
    return err
}

opengl_gpu_callback :: proc "odin" (
    user_data: rawptr,
    reference: []u8,
    m: ^Module,
    output: []u8,
) -> Error {
    return opengl_decode((^OpenGL_Context)(user_data), reference, m, output)
}

opengl_gpu_decoder :: proc(ctx: ^OpenGL_Context) -> Decoder {
    return Decoder{
        backend = .OpenGL,
        gpu_proc = opengl_gpu_callback,
        gpu_user_data = rawptr(ctx),
    }
}

opengl_allocated_bytes :: proc(ctx: ^OpenGL_Context) -> int {
    if ctx == nil { return 0 }
    return ((ctx.reference_bytes+3)/4)*4 + ctx.literal_capacity +
        ctx.phrase_capacity + ctx.output_capacity
}
