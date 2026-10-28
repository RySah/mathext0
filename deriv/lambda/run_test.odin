package deriv_lambda

import "core:math"
import "core:testing"

@(private="file")
run :: proc(t: ^testing.T, src: string, args: ..f64) -> f64 {
    l, err := parse(src)
    defer lambda_destroy(&l)
    testing.expect_value(t, err, nil)
    return lambda_run(&l, ..args)
}

@(test)
test_run :: proc(t: ^testing.T) {
    testing.expect_value(t, run(t, "x, y: x + y", 2, 3), 5)
    testing.expect_value(t, run(t, "x, y: x - y", 2, 3), -1)
    testing.expect_value(t, run(t, "x, y: x - y * 2 + 10 / y", 7, 5), 7 - 10 + 2)
    testing.expect_value(t, run(t, "x: (x + 1) * (x - 1)", 4), 15)
    testing.expect_value(t, run(t, "x: 2 ^ 3 ^ x", 2), 512)
    testing.expect_value(t, run(t, "x: -x ^ 2", 3), -9)
    testing.expect_value(t, run(t, "x: 5", 0), 5)
}

@(test)
test_run_roots :: proc(t: ^testing.T) {
    testing.expect_value(t, run(t, "x: sqrt(x)", 49), 7)
    testing.expect_value(t, run(t, "x: root(3, x)", -8), -2)
    testing.expect(t, math.abs(run(t, "x: root(3, x)", 27) - 3) < 1e-12)
}

@(test)
test_run_mapped :: proc(t: ^testing.T) {
    l, _ := parse("x, y: x - y")
    defer lambda_destroy(&l)
    m := make(map[string]f64)
    defer delete(m)
    m["y"] = 1
    m["x"] = 10
    testing.expect_value(t, lambda_run(&l, m), 9)
}
