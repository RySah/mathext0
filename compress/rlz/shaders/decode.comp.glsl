#version 450
// Each invocation owns exactly one output u32. Safe even when phrases
// begin/end at arbitrary byte boundaries. Descriptor ranges MUST be validated
// by the CPU before submission.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set=0, binding=0, std430) readonly buffer Reference { uint words[]; } ref_data;
layout(set=0, binding=1, std430) readonly buffer Literals  { uint words[]; } literal_data;
struct Phrase { uint output_offset; uint source_offset; uint length; uint kind; };
layout(set=0, binding=2, std430) readonly buffer Phrases { Phrase items[]; } phrases;
layout(set=0, binding=3, std430) writeonly buffer Output { uint words[]; } decoded;
layout(push_constant) uniform Params { uint output_size; } params;

uint get_byte(uint base, uint kind) {
    uint word_index = base >> 2u;
    uint shift = (base & 3u) * 8u;
    uint word = kind != 1u ? ref_data.words[word_index] : literal_data.words[word_index];
    return (word >> shift) & 255u;
}

uint byte_at(uint position) {
    uint lo = 0u;
    uint hi = phrases.items.length();
    // Find last phrase whose start <= position.
    while (lo < hi) {
        uint mid = lo + (hi-lo)/2u;
        if (phrases.items[mid].output_offset <= position) lo = mid + 1u;
        else hi = mid;
    }
    Phrase p = phrases.items[lo-1u];
    return get_byte(p.source_offset + position - p.output_offset, p.kind);
}

void main() {
    uint word_id = gl_GlobalInvocationID.x;
    uint start = word_id * 4u;
    if (start >= params.output_size) return;
    uint assembled = 0u;
    for (uint b = 0u; b < 4u; ++b) {
        uint at = start + b;
        if (at < params.output_size)
            assembled |= byte_at(at) << (b*8u);
    }
    decoded.words[word_id] = assembled;
}
