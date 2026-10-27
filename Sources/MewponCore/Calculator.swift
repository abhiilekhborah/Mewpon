import Foundation

public enum Calculator {
    public static func evaluate(_ text: String) throws -> Double {
        guard text.count <= 256 else { throw MewponError.invalid("Expression too long (maximum 256 characters).") }
        var parser = Parser(chars: Array(text.filter { !$0.isWhitespace }))
        let value = try parser.expression()
        guard parser.index == parser.chars.count, value.isFinite else { throw MewponError.invalid("Invalid or nonfinite arithmetic result.") }
        return value
    }
    private struct Parser {
        let chars: [Character]; var index = 0; var depth = 0
        var current: Character? { index < chars.count ? chars[index] : nil }
        mutating func consume(_ c: Character) -> Bool { if current == c { index += 1; return true }; return false }
        mutating func expression() throws -> Double {
            depth += 1; defer { depth -= 1 }
            guard depth <= 32 else { throw MewponError.invalid("Expression nesting too deep.") }
            var value = try term()
            while true {
                if consume("+") { value += try term() }
                else if consume("-") { value -= try term() }
                else { return value }
            }
        }
        mutating func term() throws -> Double {
            var value = try unary()
            while true {
                if consume("*") { value *= try unary() }
                else if consume("/") { let divisor = try unary(); guard divisor != 0 else { throw MewponError.invalid("Division by zero.") }; value /= divisor }
                else if consume("%") { let divisor = try unary(); guard divisor != 0 else { throw MewponError.invalid("Division by zero.") }; value = value.truncatingRemainder(dividingBy: divisor) }
                else { return value }
            }
        }
        mutating func unary() throws -> Double {
            depth += 1; defer { depth -= 1 }
            guard depth <= 32 else { throw MewponError.invalid("Expression nesting too deep.") }
            if consume("+") { return try unary() }
            if consume("-") { return try -unary() }
            var value = try primary()
            if consume("^") { value = pow(value, try unary()) }
            return value
        }
        mutating func primary() throws -> Double {
            if consume("(") { let value = try expression(); guard consume(")") else { throw MewponError.invalid("Missing closing parenthesis.") }; return value }
            let start = index
            while let c = current, c.isASCII && (c.isNumber || c == ".") { index += 1 }
            guard start != index, let value = Double(String(chars[start..<index])) else { throw MewponError.invalid("Expected a number or parenthesis. Only arithmetic is supported.") }
            return value
        }
    }
}
