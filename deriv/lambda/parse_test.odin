package deriv_lambda

import "core:strings"
import "core:testing"

@(private="file")
check :: proc(t: ^testing.T, src, want: string) {
    l, err := parse(src)
    defer lambda_destroy(&l)
    testing.expect_value(t, err, nil)
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    lambda_to_string(&l, l.root, &sb)
    testing.expect_value(t, strings.to_string(sb), want)
}

@(test)
test_precedence :: proc(t: ^testing.T) {
    check(t, "x, y: x + y", "(x + y)")
    check(t, "x, y: x + y * 2", "(x + (y * 2))")
    check(t, "x: (x + 1) * 2", "((x + 1) * 2)")
    check(t, "x: x - 1 - 2", "((x - 1) - 2)")
    check(t, "x: 2 ^ 3 ^ x", "(2 ^ (3 ^ x))")
    check(t, "x: -x ^ 2", "(-(x ^ 2))")
    check(t, "x: -x * 2", "((-x) * 2)")
    check(t, "x: 1.5e2 / x", "(150 / x)")
}

@(test)
test_roots :: proc(t: ^testing.T) {
    check(t, "x: sqrt(x)", "root(2, x)")
    check(t, "x: root(3, x + 1)", "root(3, (x + 1))")
}

@(test)
test_errors :: proc(t: ^testing.T) {
    cases := []struct{ src: string, kind: Parse_Error_Kind }{
        {"x: x +", .Unexpected_End},
        {"x: (x", .Expected_Close_Paren},
        {"x: y", .Unknown_Variable},
        {"x, x: x", .Duplicate_Param},
        {"x x: x", .Expected_Colon},
        {"x: foo(x)", .Unknown_Function},
        {"x: sqrt(x, 2)", .Wrong_Arg_Count},
        {"x: x $ 1", .Unexpected_Char},
        {"x: x )", .Unexpected_Token},
    }
    for c in cases {
        l, err := parse(c.src)
        lambda_destroy(&l)
        e, _ := err.(Syntax_Error)
        testing.expect_value(t, e.kind, c.kind)
    }
}
