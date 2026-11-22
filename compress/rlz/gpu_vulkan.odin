package rlz

import vk "vendor:vulkan"

// Low-level Vulkan adapter; independent of the application using the codec.
// Device must already have an RLZ compute pipeline, pipeline layout and
// descriptor set with bindings 0 reference words, 1 literals words,
// 2 phrases (std430 struct of 4 uints), 3 output words.
GPU_Context :: struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    descriptors: vk.DescriptorSet,
}

// The caller must upload reference, literals, phrases and size data beforehand;
// the shader's runtime length() on the phrase buffer provides phrase_count.
// Output buffer size must be at least ceil(output_size/4)*4 bytes.
// Requires a command buffer in recording state, outside a render pass.
// Caller handles synchronization (host->compute, compute->host), submission,
// memory visibility / invalidation and all Vk object lifetimes.
gpu_record_decode :: proc(cmd: vk.CommandBuffer, ctx: ^GPU_Context, output_size: u32, max_workgroup_count_x: u32) -> Error {
    if ctx == nil || max_workgroup_count_x == 0 { return .Invalid_Argument }
    words := (u64(output_size) + 3) / 4
    groups := (words + 63) / 64
    if groups > u64(max_workgroup_count_x) { return .Invalid_Argument }
    if groups == 0 { return .None }
    vk.CmdBindPipeline(cmd, .COMPUTE, ctx.pipeline)
    vk.CmdBindDescriptorSets(cmd, .COMPUTE, ctx.layout, 0, 1, &ctx.descriptors, 0, nil)
    size := output_size
    vk.CmdPushConstants(cmd, ctx.layout, {.COMPUTE}, 0, 4, &size)
    vk.CmdDispatch(cmd, u32(groups), 1, 1)
    return .None
}
