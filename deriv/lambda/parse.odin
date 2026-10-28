package deriv_lambda

import "core:math"
import "core:strconv"
import "core:strings"
import hm "core:container/handle_map"

/*
Parses lambda-style expressions:

    x, y: x + y
    x: sqrt(x)        // square root (degree 2)
    x: root(3, x)     // cube root: root(degree, radicand)
    x: -x ^ 2 * 3     // ^ is right associative and binds tighter than unary minus
*/

Parse_Error_Kind :: enum {
    None,
    Unexpected_Char,
    Bad_Number,
    Unexpected_Token,
    Unexpected_End,
    Expected_Colon,
    Expected_Close_Paren,
    Expected_Comma,
    Duplicate_Param,
    Too_Many_Params,
    Unknown_Variable,
    Unknown_Function,
    Wrong_Arg_Count,
    Out_Of_Memory,
}

Syntax_Error :: struct {
    kind: Parse_Error_Kind,
    pos:  int, /* byte offset into source */
}

Parse_Error :: union {Syntax_Error}

fail :: proc(kind: Parse_Error_Kind, pos: int) -> Parse_Error {
    return Syntax_Error{kind, pos}
}

Lambda :: struct {
    params: [dynamic]string, /* slices of the source string */
    root:   Expr_Handle,
    exprs:  hm.Dynamic_Handle_Map(Expr, Expr_Handle),
}

lambda_destroy :: proc(l: ^Lambda) {
    delete(l.params)
    hm.dynamic_destroy(&l.exprs)
    l^ = {}
}

lambda_get :: proc(l: ^Lambda, h: Expr_Handle) -> ^Expr {
    return hm.get(&l.exprs, h)
}

@(private="file")
Token_Kind :: enum {
    End, Number, Ident,
    Plus, Minus, Star, Slash, Caret,
    L_Paren, R_Paren, Comma, Colon,
}

@(private="file")
Token :: struct {
    kind: Token_Kind,
    text: string,
    pos:  int,
}

@(private="file")
Parser :: struct {
    src:    string,
    cur:    Token, /* current lookahead */
    next:   int,   /* scan offset */
    lambda: ^Lambda,
}

@(private="file")
is_ident_start :: proc(c: u8) -> bool {
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private="file")
is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

@(private="file")
advance :: proc(p: ^Parser) -> Parse_Error {
    s := p.src
    i := p.next
    for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') { i += 1 }

    start := i
    if i >= len(s) {
        p.cur = {.End, "", i}
        p.next = i
        return nil
    }

    c := s[i]
    kind: Token_Kind
    switch {
    case is_digit(c) || c == '.':
        for i < len(s) && (is_digit(s[i]) || s[i] == '.') { i += 1 }
        // optional exponent: 1e5, 2.5e-3
        if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
            j := i + 1
            if j < len(s) && (s[j] == '+' || s[j] == '-') { j += 1 }
            if j < len(s) && is_digit(s[j]) {
                for j < len(s) && is_digit(s[j]) { j += 1 }
                i = j
            }
        }
        kind = .Number
    case is_ident_start(c):
        for i < len(s) && (is_ident_start(s[i]) || is_digit(s[i])) { i += 1 }
        kind = .Ident
    case:
        i += 1
        switch c {
        case '+': kind = .Plus
        case '-': kind = .Minus
        case '*': kind = .Star
        case '/': kind = .Slash
        case '^': kind = .Caret
        case '(': kind = .L_Paren
        case ')': kind = .R_Paren
        case ',': kind = .Comma
        case ':': kind = .Colon
        case: return fail(.Unexpected_Char, start)
        }
    }

    p.cur = {kind, s[start:i], start}
    p.next = i
    return nil
}

@(private="file")
alloc :: proc(p: ^Parser, node: type_of(Expr{}.node)) -> (Expr_Handle, Parse_Error) {
    h, err := hm.add(&p.lambda.exprs, Expr{node = node})
    if err != nil { return {}, fail(.Out_Of_Memory, p.cur.pos) }
    return h, {}
}

/* Binding powers: (left, right). Left > right means right associative. */
@(private="file")
infix_power :: proc(k: Token_Kind) -> (l, r: int, ok: bool) {
    #partial switch k {
    case .Plus, .Minus: return 10, 11, true
    case .Star, .Slash: return 20, 21, true
    case .Caret:        return 31, 30, true
    }
    return
}

@(private="file") PREFIX_NEG_POWER :: 25

@(private="file")
parse_expr :: proc(p: ^Parser, min_power: int) -> (h: Expr_Handle, err: Parse_Error) {
    lhs := parse_prefix(p) or_return

    for {
        l, r, ok := infix_power(p.cur.kind)
        if !ok || l < min_power { break }

        op := p.cur.kind
        advance(p) or_return
        rhs := parse_expr(p, r) or_return

        pair := [2]Expr_Handle{lhs, rhs}
        #partial switch op {
        case .Plus:  lhs = alloc(p, Add_Node(pair)) or_return
        case .Minus: lhs = alloc(p, Sub_Node(pair)) or_return
        case .Star:  lhs = alloc(p, Mul_Node(pair)) or_return
        case .Slash: lhs = alloc(p, Div_Node(pair)) or_return
        case .Caret: lhs = alloc(p, Pow_Node(pair)) or_return
        }
    }
    return lhs, {}
}

@(private="file")
parse_prefix :: proc(p: ^Parser) -> (h: Expr_Handle, err: Parse_Error) {
    tok := p.cur
    #partial switch tok.kind {
    case .Number:
        v, ok := strconv.parse_f64(tok.text)
        if !ok { return {}, fail(.Bad_Number, tok.pos) }
        advance(p) or_return
        return alloc(p, v)

    case .Plus:
        advance(p) or_return
        return parse_expr(p, PREFIX_NEG_POWER)

    case .Minus:
        advance(p) or_return
        operand := parse_expr(p, PREFIX_NEG_POWER) or_return
        return alloc(p, Neg_Node(operand))

    case .L_Paren:
        advance(p) or_return
        inner := parse_expr(p, 0) or_return
        if p.cur.kind != .R_Paren { return {}, fail(.Expected_Close_Paren, p.cur.pos) }
        advance(p) or_return
        return inner, {}

    case .Ident:
        advance(p) or_return
        if p.cur.kind == .L_Paren {
            return parse_call(p, tok)
        }
        for name, i in p.lambda.params {
            if name == tok.text { return alloc(p, Var_Node(i)) }
        }
        return {}, fail(.Unknown_Variable, tok.pos)

    case .End:
        return {}, fail(.Unexpected_End, tok.pos)
    }
    return {}, fail(.Unexpected_Token, tok.pos)
}

@(private="file")
parse_call :: proc(p: ^Parser, name: Token) -> (h: Expr_Handle, err: Parse_Error) {
    advance(p) or_return // '('

    args: [2]Expr_Handle
    n := 0
    for {
        arg := parse_expr(p, 0) or_return
        if n < len(args) { args[n] = arg }
        n += 1
        if p.cur.kind == .Comma {
            advance(p) or_return
            continue
        }
        break
    }
    if p.cur.kind != .R_Paren { return {}, fail(.Expected_Close_Paren, p.cur.pos) }
    advance(p) or_return

    switch name.text {
    case "sqrt":
        if n != 1 { return {}, fail(.Wrong_Arg_Count, name.pos) }
        two := alloc(p, f64(2)) or_return
        return alloc(p, Root_Node{two, args[0]})
    case "root":
        if n != 2 { return {}, fail(.Wrong_Arg_Count, name.pos) }
        return alloc(p, Root_Node{args[0], args[1]})
    }
    return {}, fail(.Unknown_Function, name.pos)
}

parse :: proc(src: string, allocator := context.allocator) -> (l: Lambda, err: Parse_Error) {
    context.allocator = allocator
    hm.dynamic_init(&l.exprs, allocator)
    err = parse_into(&l, src)
    if err != nil {
        lambda_destroy(&l)
        l = {}
    }
    return
}

@(private="file")
parse_into :: proc(l: ^Lambda, src: string) -> (err: Parse_Error) {
    p := Parser{src = src, lambda = l}
    advance(&p) or_return

    // Parameter list: ident {',' ident} ':'. An empty list (": expr") is allowed.
    for p.cur.kind != .Colon {
        if p.cur.kind != .Ident {
            kind: Parse_Error_Kind = .Unexpected_End if p.cur.kind == .End else .Unexpected_Token
            return fail(kind, p.cur.pos)
        }
        for name in l.params {
            if name == p.cur.text { return fail(.Duplicate_Param, p.cur.pos) }
        }
        if len(l.params) > int(max(Var_Node)) { return fail(.Too_Many_Params, p.cur.pos) }
        append(&l.params, p.cur.text)
        advance(&p) or_return

        if p.cur.kind == .Comma {
            advance(&p) or_return
        } else if p.cur.kind != .Colon {
            return fail(.Expected_Colon, p.cur.pos)
        }
    }
    advance(&p) or_return // ':'

    l.root = parse_expr(&p, 0) or_return
    if p.cur.kind != .End { return fail(.Unexpected_Token, p.cur.pos) }
    return nil
}

Lambda_String_Render_Proc :: #type proc(l: ^Lambda, sb: ^strings.Builder, node: Expr_Node, data: rawptr)

render_lambda_to_string :: proc(
    l: ^Lambda, h: Expr_Handle, sb: ^strings.Builder, 
    r_data: rawptr, r: Lambda_String_Render_Proc
) {
    e := hm.get(&l.exprs, h)
    if e == nil { strings.write_string(sb, "?"); return }

    bin :: proc(l: ^Lambda, sb: ^strings.Builder, op: string, n: [2]Expr_Handle, r_data: rawptr, r: Lambda_String_Render_Proc) {
        strings.write_byte(sb, '(')
        render_lambda_to_string(l, n[0], sb, r_data, r)
        strings.write_string(sb, op)
        render_lambda_to_string(l, n[1], sb, r_data, r)
        strings.write_byte(sb, ')')
    }

    switch n in e.node {
    case f64:      r(l, sb, n, r_data)
    case Var_Node: r(l, sb, n, r_data)
    case Add_Node: bin(l, sb, " + ", ([2]Expr_Handle)(n), r_data, r)
    case Sub_Node: bin(l, sb, " - ", ([2]Expr_Handle)(n), r_data, r)
    case Mul_Node: bin(l, sb, " * ", ([2]Expr_Handle)(n), r_data, r)
    case Div_Node: bin(l, sb, " / ", ([2]Expr_Handle)(n), r_data, r)
    case Pow_Node: bin(l, sb, " ^ ", ([2]Expr_Handle)(n), r_data, r)
    case Root_Node:
        strings.write_string(sb, "root(")
        render_lambda_to_string(l, n[0], sb, r_data, r)
        strings.write_string(sb, ", ")
        render_lambda_to_string(l, n[1], sb, r_data, r)
        strings.write_byte(sb, ')')
    case Neg_Node:
        strings.write_string(sb, "(-")
        render_lambda_to_string(l, Expr_Handle(n), sb, r_data, r)
        strings.write_byte(sb, ')')
    case: strings.write_string(sb, "?")
    }
}

/* Renders an expression fully parenthesised; useful for tests and debugging. */
lambda_to_string :: proc(l: ^Lambda, h: Expr_Handle, sb: ^strings.Builder) {
    render_lambda_to_string(l, h, sb, nil, proc(l: ^Lambda, sb: ^strings.Builder, node: Expr_Node, data: rawptr) {
        #partial switch n in node {
            case f64: write_number(sb, n)
            case Var_Node: strings.write_string(sb, l.params[n])
            case: strings.write_string(sb, "?")
        }
    })
}


/* Negative literals are parenthesised so that "(-2) ^ 2" survives a re-parse. */
write_number :: proc(sb: ^strings.Builder, v: f64) {
    if v < 0 || (v == 0 && math.sign(v) < 0) {
        strings.write_byte(sb, '(')
        strings.write_f64(sb, v, 'g')
        strings.write_byte(sb, ')')
    } else {
        strings.write_f64(sb, v, 'g')
    }
}
