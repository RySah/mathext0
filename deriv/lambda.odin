package deriv

import lambda "lambda"

import "core:strings"
import "core:fmt"
import "core:mem"

sbprint_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, sb: ^strings.Builder, 
    partial_i: u8 = 0
) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    /* 
     lim       (f(x + h) - f(x)) 
    h -> 0     -----------------
                       h
    */
    assert(len(f.params) > 0) // Must accept at least one parameter
    assert(int(partial_i) < len(f.params)) // To prevent invalid parameter indexing
    
    _Data :: struct {
        h: string,
        partial_i: u8
    }

    // Distinct from user parameter names so the new variable cannot shadow them.
    h := "lim_h_0__1"
    for {
        clash := false
        for p in f.params { if p == h { clash = true } }
        if !clash { break }
        h = fmt.tprintf("%s_", h)
    }

    data := _Data{
        h=h,
        partial_i=partial_i
    }

    a_sb := strings.builder_make() or_return
    defer strings.builder_destroy(&a_sb)
    b_sb := strings.builder_make() or_return
    defer strings.builder_destroy(&b_sb)

    // f(x + h): every occurrence of the variable is shifted by h.
    lambda.render_lambda_to_string(
        f, f.root, &a_sb, &data, proc(l: ^lambda.Lambda, sb: ^strings.Builder, node: lambda.Expr_Node, data_ptr: rawptr) {
            data_ptr := (^_Data)(data_ptr)
            #partial switch n in node {
                case f64: lambda.write_number(sb, n)
                case lambda.Var_Node: 
                    if n == data_ptr.partial_i {
                        fmt.sbprintf(sb, "(%s + %s)", l.params[n], data_ptr.h)
                    }
                    else {
                        fmt.sbprintf(sb, "%s", l.params[n])
                    }
                case: strings.write_string(sb, "?")
            }
        }
    )
    lambda.lambda_to_string(f, f.root, &b_sb)

    params := strings.join(f.params[:], ", ")
    defer delete(params)

    res = fmt.sbprintf(sb, "%s, %s: ((%s) - (%s)) / (%s)", params, h, strings.to_string(a_sb), strings.to_string(b_sb), h)
    return
} 

aprint_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, 
    partial_i: u8 = 0, allocator := context.allocator
) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    sb: strings.Builder = ---
    strings.builder_init(&sb, allocator=allocator) or_return
    res = sbprint_uneval_partial_deriv(f, &sb, partial_i=partial_i) or_return
    return
}

caprint_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, 
    partial_i: u8 = 0, allocator := context.allocator
) -> (res: cstring, err: mem.Allocator_Error) #optional_allocator_error {
    sb: strings.Builder = ---
    strings.builder_init(&sb, allocator=allocator) or_return
    sbprint_uneval_partial_deriv(f, &sb, partial_i=partial_i) or_return
    res = strings.to_cstring(&sb) or_return
    return
}

tprint_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, 
    partial_i: u8 = 0
) -> (res: string, err: mem.Allocator_Error) #optional_allocator_error {
    return aprint_uneval_partial_deriv(f, partial_i=partial_i, allocator=context.temp_allocator)
}

ctprint_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, 
    partial_i: u8 = 0
) -> (res: cstring, err: mem.Allocator_Error) #optional_allocator_error {
    return caprint_uneval_partial_deriv(f, partial_i=partial_i, allocator=context.temp_allocator)
}

get_uneval_partial_deriv :: proc(
    f: ^lambda.Lambda, 
    partial_i: u8 = 0, allocator := context.allocator
) -> (res: lambda.Lambda, parser_err: lambda.Parse_Error, err: mem.Allocator_Error) {
    s := aprint_uneval_partial_deriv(f, partial_i=partial_i) or_return
    defer delete(s)

    res, parser_err = lambda.parse(s, allocator=allocator)
    return
}

