import Foundation

package struct PrivateHeaderKitSymbol: Equatable, Sendable {
    package enum Visibility: String, Sendable {
        case export
        case local
    }

    package let name: String
    package let demangledName: String
    package let visibility: Visibility

    package init(name: String, demangledName: String, visibility: Visibility) {
        self.name = name
        self.demangledName = demangledName
        self.visibility = visibility
    }
}

package struct PrivateHeaderKitSymbolList: Equatable, Sendable {
    package let imagePath: String
    package let symbols: [PrivateHeaderKitSymbol]

    package init(imagePath: String, symbols: [PrivateHeaderKitSymbol]) {
        self.imagePath = imagePath
        self.symbols = symbols
    }

    package var tsv: String {
        var result = "# image\t\(Self.escape(imagePath))\nvisibility\tname\tdemangled_name\n"
        for symbol in symbols {
            result += "\(symbol.visibility.rawValue)\t\(Self.escape(symbol.name))\t\(Self.escape(symbol.demangledName))\n"
        }
        return result
    }

    package init(tsv: String) throws {
        let lines = tsv.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0].hasPrefix("# image\t"),
              lines[1] == "visibility\tname\tdemangled_name"
        else { throw ParseError.invalidHeader }
        imagePath = try Self.unescape(lines[0].dropFirst("# image\t".count))
        var symbols: [PrivateHeaderKitSymbol] = []
        for (index, line) in lines.dropFirst(2).enumerated() {
            if line.isEmpty, index == lines.count - 3 { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let visibility = PrivateHeaderKitSymbol.Visibility(rawValue: String(fields[0]))
            else { throw ParseError.invalidRow(index + 3) }
            symbols.append(.init(
                name: try Self.unescape(fields[1]),
                demangledName: try Self.unescape(fields[2]),
                visibility: visibility
            ))
        }
        self.symbols = symbols
    }

    package enum ParseError: Error, CustomStringConvertible {
        case invalidHeader
        case invalidRow(Int)
        case invalidEscape

        package var description: String {
            switch self {
            case .invalidHeader: "invalid symbol-list header"
            case .invalidRow(let line): "invalid symbol-list row at line \(line)"
            case .invalidEscape: "invalid escape in symbol list"
            }
        }
    }

    package static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func unescape(_ value: Substring) throws -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "\\": result.append("\\")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "r": result.append("\r")
            default: throw ParseError.invalidEscape
            }
        }
        return result
    }
}
