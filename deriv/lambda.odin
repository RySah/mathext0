package deriv

import lambda "lambda"

import "core:strings"
import "core:fmt"
import "core:mem"

sbprint_uneval_deriv :: proc(f: ^lambda.Lambda, sb: ^strings.Builder) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    /* 
     lim       (f(x + h) - f(x)) 
    h -> 0     -----------------
                       h
    */
    assert(len(f.params) > 0) // Must accept at least one parameter
    assert(len(f.params) == 1) //TODO: Allow for partial derivatives.

    // deriv_lim_var := len(f.params)
    // append(&f.params, "h") or_return

    // Distinct from user parameter names so the new variable cannot shadow them.
    h := "lim_h_0__1"
    for {
        clash := false
        for p in f.params { if p == h { clash = true } }
        if !clash { break }
        h = fmt.tprintf("%s_", h)
    }

    a_sb := strings.builder_make() or_return
    defer strings.builder_destroy(&a_sb)
    b_sb := strings.builder_make() or_return
    defer strings.builder_destroy(&b_sb)

    // f(x + h): every occurrence of the variable is shifted by h.
    lambda.render_lambda_to_string(
        f, f.root, &a_sb, &h, proc(l: ^lambda.Lambda, sb: ^strings.Builder, node: lambda.Expr_Node, h_ptr: rawptr) {
            h_ptr := (^string)(h_ptr)
            #partial switch n in node {
                case f64: lambda.write_number(sb, n)
                case lambda.Var_Node: fmt.sbprintf(sb, "(%s + %s)", l.params[n], h_ptr^)
                case: strings.write_string(sb, "?")
            }
        }
    )
    lambda.lambda_to_string(f, f.root, &b_sb)

    res = fmt.sbprintf(sb, "%s, %s: ((%s) - (%s)) / (%s)", f.params[0], h, strings.to_string(a_sb), strings.to_string(b_sb), h)
    return
} 
aprint_uneval_deriv :: proc(f: ^lambda.Lambda, allocator := context.allocator) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    sb: strings.Builder = ---
    strings.builder_init(&sb, allocator=allocator) or_return
    res = sbprint_uneval_deriv(f, &sb) or_return
    return
}

caprint_uneval_deriv :: proc(f: ^lambda.Lambda, allocator := context.allocator) -> (res: cstring, err: mem.Allocator_Error) #optional_allocator_error {
    sb: strings.Builder = ---
    strings.builder_init(&sb, allocator=allocator) or_return
    sbprint_uneval_deriv(f, &sb) or_return
    res = strings.to_cstring(&sb) or_return
    return
}

tprint_uneval_deriv :: proc(f: ^lambda.Lambda) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    return aprint_uneval_deriv(f, allocator=context.temp_allocator)
}

ctprint_uneval_deriv :: proc(f: ^lambda.Lambda) -> (res: cstring, err: mem.Allocator_Error) #optional_allocator_error {
    return caprint_uneval_deriv(f, allocator=context.temp_allocator)
}

get_uneval_deriv :: proc(f: ^lambda.Lambda, allocator := context.allocator) -> (res: lambda.Lambda, parser_err: lambda.Parse_Error, err: mem.Allocator_Error) {
    s := aprint_uneval_deriv(f) or_return
    defer delete(s)

    res, parser_err = lambda.parse(s, allocator=allocator)
    return
}

