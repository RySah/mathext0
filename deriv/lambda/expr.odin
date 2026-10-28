package deriv_lambda

import hm "core:container/handle_map"
import "core:math"

Expr_Handle :: hm.Handle32


Var_Node :: u8

@(private="file") _Bin_Node :: [2]Expr_Handle

Add_Node :: distinct _Bin_Node /* a + b */
Sub_Node :: distinct _Bin_Node /* a - b */
Mul_Node :: distinct _Bin_Node /* a * b */
Div_Node :: distinct _Bin_Node /* a / b */

Root_Node :: distinct _Bin_Node /* [degree, radicand]; degree defaults to 2 */
Pow_Node :: distinct _Bin_Node /* a ^ b */
Neg_Node :: distinct Expr_Handle /* -a */

Expr_Node :: union {
    f64,
    Var_Node, /* index into Lambda.params */
    Add_Node, Sub_Node, Mul_Node, Div_Node,
    Root_Node, Pow_Node, Neg_Node,
}

Expr :: struct {
    handle: Expr_Handle,

    node: Expr_Node
}

@(private="file")
Eval_Frame :: struct {
    h:        Expr_Handle,
    expanded: bool, /* children already scheduled */
}

@(private="file")
eval_root :: proc(degree, radicand: f64) -> f64 {
    // Odd integer degrees accept negative radicands, e.g. root(3, -8) == -2.
    if radicand < 0 && degree == math.trunc(degree) && math.mod(degree, 2) != 0 {
        return -math.pow(-radicand, 1 / degree)
    }
    return math.pow(radicand, 1 / degree)
}

// Post-order evaluation with explicit stacks (no recursion).
lambda_run_with_linear_args :: proc(l: ^Lambda, args: ..f64) -> (res: f64) {
    assert(len(args) >= len(l.params), "Not enough arguments for lambda")

    frames := make([dynamic]Eval_Frame, 0, 16)
    defer delete(frames)
    values := make([dynamic]f64, 0, 16)
    defer delete(values)

    append(&frames, Eval_Frame{l.root, false})
    for len(frames) > 0 {
        f := pop(&frames)
        node := lambda_get(l, f.h).node

        if !f.expanded {
            // Push the node back, then its children so that child 0 is evaluated first.
            switch n in node {
            case f64:      append(&values, n)
            case Var_Node: append(&values, args[n])
            case Add_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Sub_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Mul_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Div_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Root_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Pow_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{n[1], false}, Eval_Frame{n[0], false})
            case Neg_Node: append(&frames, Eval_Frame{f.h, true}, Eval_Frame{Expr_Handle(n), false})
            }
            continue
        }

        // Children are on top of the value stack: operands in order a, b.
        switch n in node {
        case f64, Var_Node: unreachable()
        case Neg_Node:
            values[len(values)-1] = -values[len(values)-1]
        case Add_Node, Sub_Node, Mul_Node, Div_Node, Root_Node, Pow_Node:
            b := pop(&values)
            a := pop(&values)
            r: f64
            #partial switch _ in node {
            case Add_Node:  r = a + b
            case Sub_Node:  r = a - b
            case Mul_Node:  r = a * b
            case Div_Node:  r = a / b
            case Pow_Node:  r = math.pow(a, b)
            case Root_Node: r = eval_root(a, b)
            }
            append(&values, r)
        }
    }

    assert(len(values) == 1)
    return values[0]
}

lambda_run_with_mapped_args :: proc(l: ^Lambda, m: map[string]f64) -> f64 {
    args := make([]f64, len(l.params))
    defer delete(args)

    for name, i in l.params {
        v, found := m[name]
        assert(found, "Missing argument for lambda parameter")
        args[i] = v
    }
    return lambda_run_with_linear_args(l, ..args)
}

lambda_run :: proc{
    lambda_run_with_linear_args,
    lambda_run_with_mapped_args,
}
