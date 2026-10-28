package deriv

import lambda "lambda"
import "core:math"
import "core:testing"

@(test)
test_uneval_deriv :: proc(t: ^testing.T) {
    f, perr := lambda.parse("x: x ^ 2 + -3 * x")
    defer lambda.lambda_destroy(&f)
    testing.expect_value(t, perr, nil)

    d, derr, aerr := get_uneval_deriv(&f)
    defer lambda.lambda_destroy(&d)
    testing.expect_value(t, derr, nil)
    testing.expect_value(t, aerr, nil)
    testing.expect_value(t, len(d.params), 2)

    // f'(x) = 2x - 3, approximated with a small h
    got := lambda.lambda_run(&d, 4, 1e-6)
    testing.expect(t, math.abs(got - 5) < 1e-4, "difference quotient should approximate 2x - 3")
}

@(test)
test_uneval_deriv_negative_literal :: proc(t: ^testing.T) {
    // The literal -2 must stay a power base: (-2) ^ 2 == 4, not -(2 ^ 2).
    f, _ := lambda.parse("x: x + (-2) ^ 2")
    defer lambda.lambda_destroy(&f)
    d, derr, _ := get_uneval_deriv(&f)
    defer lambda.lambda_destroy(&d)
    testing.expect_value(t, derr, nil)
    testing.expect(t, math.abs(lambda.lambda_run(&d, 1, 1e-6) - 1) < 1e-6)
}
