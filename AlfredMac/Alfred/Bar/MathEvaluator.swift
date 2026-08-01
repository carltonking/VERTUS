import Foundation

/// Instant, local math evaluation for the Alfred bar (Spotlight-style calculator).
///
/// `evaluate` returns a formatted result string for a valid math expression, or `nil` if the
/// input isn't unambiguous math — so normal queries ("what's on my calendar") show nothing.
/// It never throws or traps: any parse error, division by zero, overflow, or invalid input
/// returns `nil`. Runs on every keystroke, so it must stay cheap and crash-free.
///
/// Supports: `+ - * / ^`, parentheses, decimals, unary minus, factorial (`n!`),
/// permutations (`P(n,k)` / `P(n k)`) and combinations (`C(n,k)` / `C(n k)`).
enum MathEvaluator {

    // Rebuilt on every keystroke otherwise; the character set is constant.
    private static let allowedChars = CharacterSet(charactersIn: "0123456789.+-*/^()!, PCpc \t")

    static func evaluate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        // Must contain a digit, only math characters, and at least one operator/function —
        // so bare words or a lone number don't render a result.
        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ Self.allowedChars.contains($0) }) else { return nil }
        let lower = trimmed.lowercased()
        let hasOp = trimmed.dropFirst().rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^!")) != nil
            || lower.contains("p(") || lower.contains("c(")
        guard hasOp else { return nil }

        var parser = Parser(trimmed)
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return format(value)
    }

    private static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%g", v)
    }

    // MARK: - Math helpers

    static func factorial(_ x: Double) -> Double? {
        guard x >= 0, x.rounded() == x, x <= 170 else { return nil }   // 170! is the largest finite Double
        var r = 1.0, n = Int(x)
        while n > 1 { r *= Double(n); n -= 1 }
        return r
    }

    /// P(n,k) = n·(n−1)·…·(n−k+1). Computed as a product to avoid building full factorials.
    static func permutations(_ n: Double, _ k: Double) -> Double {
        guard n >= 0, k >= 0, k <= n, n.rounded() == n, k.rounded() == k else { return .nan }
        var r = 1.0, i = 0
        while i < Int(k) { r *= (n - Double(i)); i += 1 }
        return r
    }

    /// C(n,k) = P(n,k) / k!.
    static func combinations(_ n: Double, _ k: Double) -> Double {
        let p = permutations(n, k)
        guard let kf = factorial(k), kf != 0 else { return .nan }
        return p / kf
    }

    // MARK: - Recursive-descent parser (returns nil on any failure; never traps)

    private struct Parser {
        let s: [Character]
        var i = 0
        init(_ str: String) { s = Array(str) }

        var isAtEnd: Bool { skipSpacesPeek() == nil }
        func skipSpacesPeek() -> Character? {
            var j = i
            while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
            return j < s.count ? s[j] : nil
        }
        mutating func skipSpaces() { while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 } }
        mutating func peek() -> Character? { skipSpaces(); return i < s.count ? s[i] : nil }
        mutating func match(_ c: Character) -> Bool { if peek() == c { i += 1; return true }; return false }

        // expression = term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var left = parseTerm() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let right = parseTerm() else { return nil }
                left = (c == "+") ? left + right : left - right
            }
            return left
        }
        // term = power (('*' | '/') power)*
        mutating func parseTerm() -> Double? {
            guard var left = parsePower() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let right = parsePower() else { return nil }
                if c == "/" { if right == 0 { return nil }; left /= right } else { left *= right }
            }
            return left
        }
        // power = postfix ('^' power)?   (right-associative)
        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if peek() == "^" {
                i += 1
                guard let exp = parsePower() else { return nil }
                return pow(base, exp)
            }
            return base
        }
        // postfix = primary '!'*   (factorial)
        mutating func parsePostfix() -> Double? {
            guard var v = parsePrimary() else { return nil }
            while peek() == "!" {
                i += 1
                guard let f = MathEvaluator.factorial(v) else { return nil }
                v = f
            }
            return v
        }
        // primary = number | '(' expression ')' | '-' primary | P(a,b) | C(a,b)
        mutating func parsePrimary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "-" { i += 1; guard let v = parsePrimary() else { return nil }; return -v }
            if c == "(" {
                i += 1
                guard let v = parseExpression(), match(")") else { return nil }
                return v
            }
            if c == "P" || c == "p" || c == "C" || c == "c" {
                i += 1
                guard match("(") else { return nil }
                guard let a = parseExpression() else { return nil }
                _ = match(",")   // args may be comma- OR whitespace-separated ("P(17 3)")
                guard let b = parseExpression(), match(")") else { return nil }
                return (c == "P" || c == "p") ? MathEvaluator.permutations(a, b) : MathEvaluator.combinations(a, b)
            }
            return parseNumber()
        }
        mutating func parseNumber() -> Double? {
            skipSpaces()
            let start = i
            while i < s.count, s[i].isNumber || s[i] == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(s[start..<i]))
        }
    }
}
