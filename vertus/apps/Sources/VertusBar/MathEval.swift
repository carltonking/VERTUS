import Foundation

/// Live math engine for the Quick Bar: turns whatever the user is typing
/// into a result on EVERY keystroke, so no Enter is needed for anything
/// that looks like math. Supports plain arithmetic ("9+9", "(1+2)^3"),
/// functions ("sqrt(9)", "min(1,2)"), constants (pi, e, τ), implicit
/// multiplication ("2pi", "2(3)"), postfix "!" and "%", and a few LaTeX
/// forms — "\frac{1}{2}" or "frac{1}{2}", "\sqrt{9}" or "sqrt{9}" or
/// "√9", "\times"/"·"/"\cdot"/"\div", "\left( … \right)".
struct MathEvaluator {

    /// A successfully parsed expression: its numeric value plus a
    /// human-readable re-rendering (LaTeX normalized, e.g.
    /// `frac{1}{2}` → "1 / 2").
    struct Result {
        let value: Double
        let rendered: String
    }

    struct ParseError: Error {}

    // MARK: - Public API

    /// Nil unless the ENTIRE input parses as a math expression (a single
    /// trailing "=" is tolerated, e.g. "9+9=").
    static func evaluate(_ input: String) -> Result? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let tokens = tokenize(trimmed) else { return nil }
        var parser = Parser(tokens: tokens)
        do {
            let expr = try parser.parseFull()
            return Result(value: try value(expr), rendered: render(expr))
        } catch {
            return nil
        }
    }

    /// True when the input is a math expression *in progress* — e.g. "9+"
    /// or "sqrt(9" — used to keep the calculator window open on every
    /// keystroke instead of flickering it shut mid-expression. The stream
    /// must START like math (number, group, unary sign, \command, or a
    /// math keyword), contain no stray closing paren/brace, and the
    /// tokenizer must have accepted every character (so sentences like
    /// "what is 9+9" or "call me at 5" never engage it).
    static func isMathInProgress(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let tokens = tokenize(t), let first = tokens.first else { return false }
        switch first {
        case .number, .lparen, .lbrace:
            break
        case .op(let o):
            // Leading minus/plus only (a leading "("-less expression).
            if o != "-" && o != "−" && o != "+" { return false }
        case .latex:
            break
        case .name(let raw):
            let l = raw.lowercased()
            let keywords: Set<String> = [
                "pi", "tau", "e", "infinity", "frac", "dfrac", "sqrt",
                "sin", "cos", "tan", "asin", "acos", "atan",
                "sinh", "cosh", "tanh", "ln", "log", "log2", "log10",
                "exp", "abs", "floor", "ceil", "round", "trunc", "sign",
                "cbrt", "min", "max", "mod",
            ]
            if l != "π" && l != "√" && l != "∞" && !keywords.contains(l) { return false }
        default:
            return false
        }
        // Groups must never close more than they have opened.
        var depth = 0
        for token in tokens {
            switch token {
            case .lparen, .lbrace: depth += 1
            case .rparen, .rbrace:
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return true
    }

    /// Compact display formatting: integers without decimals, floats
    /// trimmed to 10 significant digits, "∞"/"−∞" for overflow, and
    /// "undefined" for NaN (0/0, sqrt of a negative, …).
    static func format(_ d: Double) -> String {
        if d.isNaN { return "undefined" }
        if d.isInfinite { return d > 0 ? "∞" : "−∞" }
        if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.0f", d) }
        return String(format: "%.10g", d)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case name(String)      // identifier: pi, e, sqrt, frac, min, …
        case latex(String)     // \command (backslash already consumed)
        case op(String)        // + - * / ^ ! % , = × ÷ · −
        case lparen
        case rparen
        case lbrace
        case rbrace
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace { i = s.index(after: i); continue }
            // Number (int or decimal).
            if c.isNumber || c == "." {
                var seenDot = false
                var j = i
                while j < s.endIndex {
                    let ch = s[j]
                    if ch.isNumber { j = s.index(after: j) }
                    else if ch == "." && !seenDot { seenDot = true; j = s.index(after: j) }
                    else { break }
                }
                guard let val = Double(String(s[i..<j])) else { return nil }
                tokens.append(.number(val))
                i = j
                continue
            }
            // Identifier (also π, ∞, and the √ shorthand for sqrt).
            if c.isLetter || c == "π" || c == "∞" || c == "√" {
                var j = i
                while j < s.endIndex, s[j].isLetter || s[j] == "π" || s[j] == "∞" || s[j] == "√" {
                    j = s.index(after: j)
                }
                tokens.append(.name(String(s[i..<j])))
                i = j
                continue
            }
            // LaTeX command.
            if c == "\\" {
                var j = s.index(after: i)
                while j < s.endIndex, s[j].isLetter { j = s.index(after: j) }
                guard j > s.index(after: i) else { return nil }   // lone backslash
                let cmd = String(s[i..<j].dropFirst()).lowercased()
                // \left( … \right) — the parens already group; swallow the words.
                if cmd == "left" || cmd == "right" {
                    i = j
                    continue
                }
                tokens.append(.latex(cmd))
                i = j
                continue
            }
            switch c {
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "{": tokens.append(.lbrace)
            case "}": tokens.append(.rbrace)
            case "+", "-", "*", "/", "^", "!", "%", ",", "=", "×", "÷", "·", "−":
                tokens.append(.op(String(c)))
            default:
                return nil
            }
            i = s.index(after: i)
        }
        return tokens
    }

    // MARK: - AST + evaluation

    private indirect enum Expr {
        case number(Double)
        case constant(String)      // "pi", "e", "tau", "∞"
        case neg(Expr)
        case add(Expr, Expr)
        case sub(Expr, Expr)
        case mul(Expr, Expr)
        case div(Expr, Expr)
        case pow(Expr, Expr)
        case call(String, [Expr])  // sin(…), min(…), …
        case frac(Expr, Expr)      // \frac{a}{b}
        case sqrt(Expr)
        case fact(Expr)            // 5!
        case percent(Expr)         // 50%
    }

    /// Evaluates the tree. Only structural errors throw; domain mistakes
    /// (1/0, sqrt(-4), 0/0) flow through as ±∞ / NaN so the caller can
    /// render "∞" / "undefined".
    private static func value(_ e: Expr) throws -> Double {
        switch e {
        case .number(let v): return v
        case .constant(let c):
            switch c {
            case "pi": return .pi
            case "tau": return 2 * .pi
            case "e": return M_E
            case "∞": return .infinity
            default: throw ParseError()
            }
        case .neg(let a): return -(try value(a))
        case .add(let a, let b): return try value(a) + value(b)
        case .sub(let a, let b): return try value(a) - value(b)
        case .mul(let a, let b): return try value(a) * value(b)
        case .div(let a, let b): return try value(a) / value(b)
        case .pow(let a, let b): return pow(try value(a), try value(b))
        case .fact(let a):
            let v = try value(a)
            guard v >= 0, v == v.rounded(), v <= 170 else { return .nan }
            var acc = 1.0
            var k = Int(v)
            while k > 1 { acc *= Double(k); k -= 1 }
            return acc
        case .percent(let a): return try value(a) / 100
        case .frac(let n, let d): return try value(n) / value(d)
        case .sqrt(let a):
            let v = try value(a)
            return v < 0 ? .nan : sqrt(v)
        case .call(let name, let args):
            let v = try args.map(value)
            switch name {
            case "sqrt":  return v[0] < 0 ? .nan : sqrt(v[0])
            case "cbrt":  return cbrt(v[0])
            case "abs":   return abs(v[0])
            case "sign":  return v[0] == 0 ? 0 : (v[0] > 0 ? 1 : -1)
            case "sin":   return sin(v[0])
            case "cos":   return cos(v[0])
            case "tan":   return tan(v[0])
            case "asin":  return asin(v[0])
            case "acos":  return acos(v[0])
            case "atan":  return atan(v[0])
            case "sinh":  return sinh(v[0])
            case "cosh":  return cosh(v[0])
            case "tanh":  return tanh(v[0])
            case "ln":    return log(v[0])
            case "log":   return log10(v[0])
            case "log2":  return log2(v[0])
            case "log10": return log10(v[0])
            case "exp":   return exp(v[0])
            case "floor": return floor(v[0])
            case "ceil":  return ceil(v[0])
            case "round": return round(v[0])
            case "trunc": return trunc(v[0])
            case "mod":   return v[0].truncatingRemainder(dividingBy: v[1])
            case "min":   return v.min() ?? 0
            case "max":   return v.max() ?? 0
            default: throw ParseError()
            }
        }
    }

    // MARK: - Parser (recursive descent)

    /// Grammar (all left-assoc except `^`, which is right-assoc):
    ///   expr   := term (('+'|'-') term)*
    ///   term   := factor (('*'|'/'|'\times'|'\div'|'\cdot'| implicit) factor)*
    ///   factor := postfix ('^' factor)?
    ///   postfix:= unary ('!'|'%')*
    ///   unary  := ('-'|'+') unary | atom
    ///   atom   := number | constant | '(' expr ')' | '{' expr '}'
    ///           | function '(' args ')' | function '{' expr '}'
    ///           | '\frac{a}{b}' | '\sqrt{x}' | '√' unary
    private struct Parser {
        let tokens: [Token]
        var pos = 0

        var current: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseFull() throws -> Expr {
            let e = try parseExpr()
            // A single trailing "=" is fine ("9+9="), then end of input.
            if matchOp("=") {
                guard current == nil else { throw ParseError() }
            }
            guard current == nil else { throw ParseError() }
            return e
        }

        mutating func parseExpr() throws -> Expr {
            var lhs = try parseTerm()
            while true {
                if matchOp("+") {
                    lhs = .add(lhs, try parseTerm())
                } else if matchOp("-") || matchOp("−") {
                    lhs = .sub(lhs, try parseTerm())
                } else { break }
            }
            return lhs
        }

        mutating func parseTerm() throws -> Expr {
            var lhs = try parseFactor()
            while true {
                if matchOp("*") || matchOp("×") || matchOp("·") {
                    lhs = .mul(lhs, try parseFactor())
                } else if matchOp("/") || matchOp("÷") {
                    lhs = .div(lhs, try parseFactor())
                } else if case .latex(let cmd)? = current, cmd == "times" || cmd == "cdot" {
                    pos += 1
                    lhs = .mul(lhs, try parseFactor())
                } else if case .latex(let cmd)? = current, cmd == "div" {
                    pos += 1
                    lhs = .div(lhs, try parseFactor())
                } else if startsAtom(current) {
                    // Implicit multiplication: "2pi", "2(3)", "(2)(3)".
                    lhs = .mul(lhs, try parseFactor())
                } else { break }
            }
            return lhs
        }

        mutating func parseFactor() throws -> Expr {
            let base = try parsePostfix()
            if matchOp("^") {
                return .pow(base, try parseFactor())   // right-associative
            }
            return base
        }

        mutating func parsePostfix() throws -> Expr {
            var e = try parseUnary()
            while true {
                if matchOp("!") { e = .fact(e) }
                else if matchOp("%") { e = .percent(e) }
                else { break }
            }
            return e
        }

        mutating func parseUnary() throws -> Expr {
            if matchOp("-") || matchOp("−") { return .neg(try parseUnary()) }
            if matchOp("+") { return try parseUnary() }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> Expr {
            switch current {
            case .number(let v)?:
                pos += 1
                return .number(v)
            case .lparen?:
                pos += 1
                let e = try parseExpr()
                try expect(.rparen)
                return e
            case .lbrace?:
                pos += 1
                let e = try parseExpr()
                try expect(.rbrace)
                return e
            case .name(let name)?:
                pos += 1
                return try parseName(name)
            case .latex(let cmd)?:
                pos += 1
                return try parseLatex(cmd)
            default:
                throw ParseError()
            }
        }

        private mutating func parseName(_ raw: String) throws -> Expr {
            switch raw.lowercased() {
            case "pi", "π": return .constant("pi")
            case "tau": return .constant("tau")
            case "e": return .constant("e")
            case "infinity", "∞": return .constant("∞")
            case "frac", "dfrac":
                // Bare "frac{1}{2}" (no backslash) is tolerated.
                let a = try parseBracedGroup()
                let b = try parseBracedGroup()
                return .frac(a, b)
            case "sqrt", "√":
                if case .lparen? = current {
                    let args = try parseCommaArgs()
                    guard let first = args.first else { throw ParseError() }
                    return .sqrt(first)
                }
                if case .lbrace? = current { return .sqrt(try parseBracedGroup()) }
                return .sqrt(try parseUnary())
            case "min", "max":
                return .call(raw.lowercased(), try parseCommaArgs())
            default:
                return try parseFunctionCall(raw.lowercased())
            }
        }

        private mutating func parseLatex(_ cmd: String) throws -> Expr {
            switch cmd {
            case "frac", "dfrac":
                let a = try parseBracedGroup()
                let b = try parseBracedGroup()
                return .frac(a, b)
            case "sqrt":
                return .sqrt(try parseBracedGroup())
            case "pi": return .constant("pi")
            case "tau": return .constant("tau")
            case "infty": return .constant("∞")
            default:
                return try parseFunctionCall(cmd)
            }
        }

        /// sin(x), log(100), abs{-3} … — a function followed by a paren
        /// or brace group with zero or more comma-separated arguments.
        private mutating func parseFunctionCall(_ name: String) throws -> Expr {
            if case .lparen? = current {
                return .call(name, try parseCommaArgs())
            }
            if case .lbrace? = current {
                return .call(name, [try parseBracedGroup()])
            }
            throw ParseError()
        }

        /// Assumes the current token is "{", parses "{ expr }".
        private mutating func parseBracedGroup() throws -> Expr {
            try expect(.lbrace)
            let e = try parseExpr()
            try expect(.rbrace)
            return e
        }

        /// "(" followed by comma-separated expressions followed by ")".
        private mutating func parseCommaArgs() throws -> [Expr] {
            try expect(.lparen)
            var args: [Expr] = []
            if case .rparen? = current {
                pos += 1
                return args
            }
            while true {
                args.append(try parseExpr())
                if matchOp(",") { continue }
                try expect(.rparen)
                return args
            }
        }

        private mutating func expect(_ token: Token) throws {
            guard current == token else { throw ParseError() }
            pos += 1
        }

        private mutating func matchOp(_ op: String) -> Bool {
            if case .op(let o)? = current, o == op {
                pos += 1
                return true
            }
            return false
        }

        private func startsAtom(_ token: Token?) -> Bool {
            switch token {
            case .number, .name, .latex, .lparen, .lbrace: return true
            default: return false
            }
        }
    }

    // MARK: - Pretty re-rendering

    /// Normalized text form of the expression (what the chip shows dimmed
    /// above the answer). `minPrec` is the precedence of the enclosing
    /// context; a node re-parenthesizes itself when its own precedence is
    /// lower, so "(1+2)^3" survives as "(1 + 2) ^ 3".
    private static func render(_ e: Expr, minPrec: Int = 0) -> String {
        switch e {
        case .number(let v):
            return format(v)
        case .constant(let c):
            switch c {
            case "pi": return "π"
            case "tau": return "τ"
            case "e": return "e"
            default: return "∞"
            }
        case .neg(let a):
            let s = "-" + render(a, minPrec: 4)
            return minPrec > 3 ? "(\(s))" : s
        case .add(let a, let b):
            let s = "\(render(a, minPrec: 2)) + \(render(b, minPrec: 2))"
            return minPrec > 1 ? "(\(s))" : s
        case .sub(let a, let b):
            let s = "\(render(a, minPrec: 2)) - \(render(b, minPrec: 2))"
            return minPrec > 1 ? "(\(s))" : s
        case .mul(let a, let b):
            let s = "\(render(a, minPrec: 3)) × \(render(b, minPrec: 3))"
            return minPrec > 2 ? "(\(s))" : s
        case .div(let a, let b):
            let s = "\(render(a, minPrec: 3)) / \(render(b, minPrec: 3))"
            return minPrec > 2 ? "(\(s))" : s
        case .pow(let a, let b):
            let s = "\(render(a, minPrec: 4)) ^ \(render(b, minPrec: 4))"
            return minPrec > 4 ? "(\(s))" : s
        case .fact(let a):
            let s = render(a, minPrec: 4) + "!"
            return minPrec > 4 ? "(\(s))" : s
        case .percent(let a):
            let s = render(a, minPrec: 3) + "%"
            return minPrec > 4 ? "(\(s))" : s
        case .frac(let a, let b):
            let s = "\(render(a, minPrec: 3)) / \(render(b, minPrec: 3))"
            return minPrec > 2 ? "(\(s))" : s
        case .sqrt(let a):
            let s = "√\(render(a, minPrec: 4))"
            return minPrec > 4 ? "(\(s))" : s
        case .call(let name, let args):
            let s = name + "(" + args.map { render($0, minPrec: 2) }.joined(separator: ", ") + ")"
            return minPrec > 5 ? "(\(s))" : s
        }
    }
}