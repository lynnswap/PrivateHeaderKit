import Demangling
import Foundation
import ObjCDump

struct ResolvedSwiftObjCName: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case objcRuntimeName
        case runtimeQualifiedName
        case classMetadataSymbol
    }

    enum Kind: Equatable, Sendable {
        case `class`
        case `protocol`
    }

    let rawName: String
    let source: Source
    let kind: Kind
    let displayName: String
    let canonicalName: String
    let objcIdentifier: String
    let fileStem: String
}

private extension ResolvedSwiftObjCName.Kind {
    var hashDiscriminator: String {
        switch self {
        case .class: "class"
        case .protocol: "protocol"
        }
    }
}

enum SwiftObjCNameLookup: Equatable, Sendable {
    case notSwift
    case unavailable(rawName: String)
    case resolved(ResolvedSwiftObjCName)
}

enum SwiftObjCNameResolver {
    private static let objcIdentifierPrefix = "PHKSwift__"
    private static let maxReadableIdentifierBytes = 96
    private static let maxPortableFileStemBytes = 200
    private static let hashLength = 16

    static func resolve(_ rawName: String) -> SwiftObjCNameLookup {
        let source: ResolvedSwiftObjCName.Source
        if rawName.hasPrefix("_Tt") {
            source = .objcRuntimeName
        } else if rawName.hasPrefix("_$s") || rawName.hasPrefix("$s") {
            guard rawName.hasSuffix("N") else {
                return .unavailable(rawName: rawName)
            }
            source = .classMetadataSymbol
        } else {
            return .notSwift
        }

        guard rawName.unicodeScalars.allSatisfy({
            $0.properties.generalCategory != .control
        }) else {
            return .unavailable(rawName: rawName)
        }

        do {
            let root = try demangleAsNode(rawName, internsSubtrees: false)
            guard let extracted = extractType(from: root, source: source) else {
                return .unavailable(rawName: rawName)
            }
            let displayName = extracted.node.print(using: .default)
            guard isValidDisplayName(displayName) else {
                return .unavailable(rawName: rawName)
            }
            return resolvedName(
                rawName: rawName,
                source: source,
                kind: extracted.kind,
                displayName: displayName
            )
        } catch {
            return .unavailable(rawName: rawName)
        }
    }

    static func resolveRuntimeOriginClassName(_ rawName: String) -> SwiftObjCNameLookup {
        let lookup = resolve(rawName)
        switch lookup {
        case .resolved, .unavailable:
            return lookup
        case .notSwift:
            // Only runtime enumeration may promote Module.Type to a Swift identity;
            // the same spelling in static metadata remains an ordinary ObjC name.
            guard isStrictRuntimeQualifiedClassName(rawName) else {
                return .notSwift
            }
            return resolvedName(
                rawName: rawName,
                source: .runtimeQualifiedName,
                kind: .class,
                displayName: rawName
            )
        }
    }

    static func portableFileStem(
        displayName: String,
        canonicalName: String
    ) -> String {
        let hash = stableHashHex("\(displayName)\u{0}\(canonicalName)")
        return portableFileStem(
            displayName: displayName,
            canonicalName: canonicalName,
            hash: hash
        )
    }

    private static func extractType(
        from root: Node,
        source: ResolvedSwiftObjCName.Source
    ) -> (node: Node, kind: ResolvedSwiftObjCName.Kind)? {
        guard root.kind == .global, root.children.count == 1,
              let rootPayload = root.firstChild
        else { return nil }

        switch source {
        case .runtimeQualifiedName:
            return nil
        case .objcRuntimeName:
            guard rootPayload.kind == .typeMangling,
                  rootPayload.children.count == 1,
                  let typeWrapper = rootPayload.firstChild,
                  typeWrapper.kind == .type,
                  typeWrapper.children.count == 1,
                  let typeNode = typeWrapper.firstChild
            else { return nil }
            switch typeNode.kind {
            case .class, .boundGenericClass:
                return (typeNode, .class)
            case .protocolList:
                guard typeNode.children.count == 1,
                      let typeList = typeNode.firstChild,
                      typeList.kind == .typeList,
                      typeList.children.count == 1,
                      let protocolType = typeList.firstChild,
                      protocolType.kind == .type,
                      protocolType.children.count == 1,
                      let protocolNode = protocolType.firstChild,
                      protocolNode.kind == .protocol
                else { return nil }
                return (protocolNode, .protocol)
            default:
                return nil
            }

        case .classMetadataSymbol:
            guard rootPayload.kind == .typeMetadata,
                  rootPayload.children.count == 1,
                  let typeWrapper = rootPayload.firstChild,
                  typeWrapper.kind == .type,
                  typeWrapper.children.count == 1,
                  let typeNode = typeWrapper.firstChild,
                  typeNode.kind == .class || typeNode.kind == .boundGenericClass
            else { return nil }
            return (typeNode, .class)
        }
    }

    private static func resolvedName(
        rawName: String,
        source: ResolvedSwiftObjCName.Source,
        kind: ResolvedSwiftObjCName.Kind,
        displayName: String
    ) -> SwiftObjCNameLookup {
        // Hash the extracted type identity, not its source symbol. Legacy `_Tt`
        // names and modern `...CN` metadata symbols for one type must share an alias.
        let canonicalName = "\(kind.hashDiscriminator):\(displayName)"
        let hash = stableHashHex(canonicalName)
        return .resolved(
            ResolvedSwiftObjCName(
                rawName: rawName,
                source: source,
                kind: kind,
                displayName: displayName,
                canonicalName: canonicalName,
                objcIdentifier: objcIdentifier(displayName: displayName, hash: hash),
                fileStem: portableFileStem(
                    displayName: displayName,
                    canonicalName: canonicalName,
                    hash: hash
                )
            )
        )
    }

    private static func isStrictRuntimeQualifiedClassName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first,
                  first == "_" || isASCIIAlpha(first)
            else { return false }
            return component.unicodeScalars.dropFirst().allSatisfy {
                $0 == "_" || isASCIIAlpha($0) || ($0.value >= 48 && $0.value <= 57)
            }
        }
    }

    private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        scalar.isASCII
            && ((scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122))
    }

    private static func isValidDisplayName(_ displayName: String) -> Bool {
        !displayName.isEmpty
            && displayName.unicodeScalars.allSatisfy {
                $0.properties.generalCategory != .control
            }
    }

    private static func objcIdentifier(displayName: String, hash: String) -> String {
        var readable = sanitizedASCII(
            displayName,
            allowedPunctuation: [],
            replacement: "_"
        )
        readable = readable.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if readable.isEmpty {
            readable = "Type"
        }
        readable = String(readable.prefix(maxReadableIdentifierBytes))
        return "\(objcIdentifierPrefix)\(readable)__\(hash)"
    }

    private static func portableFileStem(
        displayName: String,
        canonicalName: String,
        hash: String
    ) -> String {
        var stem = sanitizedASCII(
            displayName,
            allowedPunctuation: [".", "-", "+"],
            replacement: "_"
        )
        if stem.isEmpty || stem == "." || stem == ".." {
            stem = "SwiftType"
        }
        guard stem.utf8.count > maxPortableFileStemBytes else {
            return stem
        }
        let suffix = "~\(hash)"
        let prefixBytes = maxPortableFileStemBytes - suffix.utf8.count
        let prefix = String(stem.prefix(prefixBytes))
        precondition(!canonicalName.isEmpty, "resolved Swift name must have a canonical identity")
        return prefix + suffix
    }

    private static func sanitizedASCII(
        _ value: String,
        allowedPunctuation: Set<UnicodeScalar>,
        replacement: Character
    ) -> String {
        var result = ""
        var previousWasReplacement = false
        for scalar in value.unicodeScalars {
            let isASCIIAlphanumeric = scalar.isASCII
                && ((scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122))
            if isASCIIAlphanumeric || scalar == "_" || allowedPunctuation.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasReplacement = false
            } else if !previousWasReplacement {
                result.append(replacement)
                previousWasReplacement = true
            }
        }
        return result
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        if hex.count >= hashLength {
            return hex
        }
        return String(repeating: "0", count: hashLength - hex.count) + hex
    }
}

enum SwiftObjCHeaderRendering {
    static func classEntry(
        _ info: ObjCClassInfo,
        runtimeOrigin: Bool = false
    ) -> ObjCHeaderEntry {
        var projection = Projection(allowsRuntimeQualifiedClassNames: runtimeOrigin)
        let ownName = projection.name(info.name, expectedKind: .class)
        let renderedInfo = ObjCClassInfo(
            name: ownName.outputName,
            version: info.version,
            imageName: info.imageName,
            instanceSize: info.instanceSize,
            superClassName: info.superClassName.map {
                projection.name($0, expectedKind: .class).outputName
            },
            protocols: info.protocols.map { projection.protocolReference($0) },
            ivars: info.ivars.map { projection.ivar($0) },
            classProperties: info.classProperties.map { projection.property($0) },
            properties: info.properties.map { projection.property($0) },
            classMethods: info.classMethods.map { projection.method($0) },
            methods: info.methods.map { projection.method($0) }
        )
        return ObjCHeaderEntry(
            symbolKind: .class,
            rawIdentity: info.name,
            displayBaseName: ownName.resolved?.fileStem ?? info.name,
            headerString: projection.headerString(
                renderedInfo.headerString,
                runtimeName: ownName.runtimeName(for: .class)
            )
        )
    }

    static func protocolEntry(_ info: ObjCProtocolInfo) -> ObjCHeaderEntry {
        var projection = Projection(allowsRuntimeQualifiedClassNames: false)
        let ownName = projection.name(info.name, expectedKind: .protocol)
        let renderedInfo = ObjCProtocolInfo(
            name: ownName.outputName,
            protocols: info.protocols.map { projection.protocolReference($0) },
            classProperties: info.classProperties.map { projection.property($0) },
            properties: info.properties.map { projection.property($0) },
            classMethods: info.classMethods.map { projection.method($0) },
            methods: info.methods.map { projection.method($0) },
            optionalClassProperties: info.optionalClassProperties.map { projection.property($0) },
            optionalProperties: info.optionalProperties.map { projection.property($0) },
            optionalClassMethods: info.optionalClassMethods.map { projection.method($0) },
            optionalMethods: info.optionalMethods.map { projection.method($0) }
        )
        return ObjCHeaderEntry(
            symbolKind: .protocol,
            rawIdentity: info.name,
            displayBaseName: ownName.resolved?.fileStem ?? info.name,
            headerString: projection.headerString(
                renderedInfo.headerString,
                runtimeName: ownName.runtimeName(for: .protocol)
            )
        )
    }

    static func categoryEntry(_ info: ObjCCategoryInfo) -> ObjCHeaderEntry {
        var projection = Projection(allowsRuntimeQualifiedClassNames: false)
        let className = projection.name(info.className, expectedKind: .class)
        let renderedInfo = ObjCCategoryInfo(
            name: info.name,
            className: className.outputName,
            protocols: info.protocols.map { projection.protocolReference($0) },
            classProperties: info.classProperties.map { projection.property($0) },
            properties: info.properties.map { projection.property($0) },
            classMethods: info.classMethods.map { projection.method($0) },
            methods: info.methods.map { projection.method($0) }
        )
        let rawIdentity = "\(info.className)+\(info.name)"
        let displayBaseName: String
        if let resolved = className.resolved {
            displayBaseName = SwiftObjCNameResolver.portableFileStem(
                displayName: "\(resolved.displayName)+\(info.name)",
                canonicalName: "\(resolved.canonicalName)\u{0}category\u{0}\(info.name)"
            )
        } else {
            displayBaseName = rawIdentity
        }
        return ObjCHeaderEntry(
            symbolKind: .category,
            rawIdentity: rawIdentity,
            displayBaseName: displayBaseName,
            headerString: projection.headerString(renderedInfo.headerString, runtimeName: nil)
        )
    }
}

private extension SwiftObjCHeaderRendering {
    enum Annotation: Equatable {
        case resolved(String)
        case unavailable
    }

    struct ProjectedName {
        let rawName: String
        let outputName: String
        let resolved: ResolvedSwiftObjCName?

        func runtimeName(for expectedKind: ResolvedSwiftObjCName.Kind) -> String? {
            guard let resolved,
                  (resolved.source == .objcRuntimeName
                    || resolved.source == .runtimeQualifiedName),
                  resolved.kind == expectedKind
            else { return nil }
            return rawName
        }
    }

    struct Projection {
        let allowsRuntimeQualifiedClassNames: Bool
        private var annotations: [String: Annotation] = [:]

        init(allowsRuntimeQualifiedClassNames: Bool) {
            self.allowsRuntimeQualifiedClassNames = allowsRuntimeQualifiedClassNames
        }

        mutating func name(
            _ rawName: String,
            expectedKind: ResolvedSwiftObjCName.Kind
        ) -> ProjectedName {
            let lookup = if expectedKind == .class && allowsRuntimeQualifiedClassNames {
                SwiftObjCNameResolver.resolveRuntimeOriginClassName(rawName)
            } else {
                SwiftObjCNameResolver.resolve(rawName)
            }
            switch lookup {
            case .notSwift:
                return ProjectedName(rawName: rawName, outputName: rawName, resolved: nil)
            case .unavailable:
                record(.unavailable, for: rawName)
                return ProjectedName(rawName: rawName, outputName: rawName, resolved: nil)
            case .resolved(let resolved):
                guard resolved.kind == expectedKind else {
                    record(.unavailable, for: rawName)
                    return ProjectedName(rawName: rawName, outputName: rawName, resolved: nil)
                }
                record(.resolved(resolved.displayName), for: rawName)
                return ProjectedName(
                    rawName: rawName,
                    outputName: resolved.objcIdentifier,
                    resolved: resolved
                )
            }
        }

        mutating func protocolReference(_ info: ObjCProtocolInfo) -> ObjCProtocolInfo {
            let projectedName = name(info.name, expectedKind: .protocol).outputName
            return ObjCProtocolInfo(
                name: projectedName,
                protocols: [],
                classProperties: [],
                properties: [],
                classMethods: [],
                methods: [],
                optionalClassProperties: [],
                optionalProperties: [],
                optionalClassMethods: [],
                optionalMethods: []
            )
        }

        mutating func ivar(_ info: ObjCIvarInfo) -> ObjCIvarInfo {
            ObjCIvarInfo(
                name: info.name,
                typeEncoding: rewrittenTypeEncoding(info.typeEncoding),
                offset: info.offset
            )
        }

        mutating func property(_ info: ObjCPropertyInfo) -> ObjCPropertyInfo {
            ObjCPropertyInfo(
                name: info.name,
                attributesString: rewrittenTypeEncoding(info.attributesString),
                isClassProperty: info.isClassProperty
            )
        }

        mutating func method(_ info: ObjCMethodInfo) -> ObjCMethodInfo {
            ObjCMethodInfo(
                name: info.name,
                typeEncoding: rewrittenTypeEncoding(info.typeEncoding),
                isClassMethod: info.isClassMethod,
                imp: info.imp
            )
        }

        mutating func headerString(_ body: String, runtimeName: String?) -> String {
            var prefix = annotations.keys.sorted().map { rawName in
                switch annotations[rawName] {
                case .resolved(let displayName):
                    "// Swift name: \(rawName) -> \(displayName)"
                case .unavailable:
                    "// Swift name unavailable: \(rawName)"
                case nil:
                    preconditionFailure("annotation key must have a value")
                }
            }
            if let runtimeName {
                prefix.append(
                    "__attribute__((objc_runtime_name(\"\(escapedCString(runtimeName))\")))"
                )
            }
            guard !prefix.isEmpty else { return body }
            prefix.append(body)
            return prefix.joined(separator: "\n")
        }

        private mutating func rewrittenTypeEncoding(_ encoding: String) -> String {
            var result = ""
            var cursor = encoding.startIndex
            while cursor < encoding.endIndex {
                let next = encoding.index(after: cursor)
                guard encoding[cursor] == "@",
                      next < encoding.endIndex,
                      encoding[next] == "\""
                else {
                    result.append(encoding[cursor])
                    cursor = next
                    continue
                }

                result += "@\""
                let contentStart = encoding.index(after: next)
                guard let closingQuote = closingQuote(in: encoding, from: contentStart) else {
                    result.append(contentsOf: encoding[contentStart...])
                    return result
                }
                let descriptor = String(encoding[contentStart..<closingQuote])
                result += rewrittenObjectDescriptor(descriptor)
                result.append("\"")
                cursor = encoding.index(after: closingQuote)
            }
            return result
        }

        private func closingQuote(in value: String, from start: String.Index) -> String.Index? {
            var cursor = start
            var escaped = false
            while cursor < value.endIndex {
                let character = value[cursor]
                if character == "\"" && !escaped {
                    return cursor
                }
                if character == "\\" {
                    escaped.toggle()
                } else {
                    escaped = false
                }
                cursor = value.index(after: cursor)
            }
            return nil
        }

        private mutating func rewrittenObjectDescriptor(_ descriptor: String) -> String {
            guard let firstProtocolStart = descriptor.firstIndex(of: "<") else {
                return name(descriptor, expectedKind: .class).outputName
            }

            var result = ""
            let className = String(descriptor[..<firstProtocolStart])
            if !className.isEmpty {
                result += name(className, expectedKind: .class).outputName
            }
            var cursor = firstProtocolStart
            while cursor < descriptor.endIndex {
                guard descriptor[cursor] == "<",
                      let close = descriptor[cursor...].firstIndex(of: ">")
                else {
                    result.append(contentsOf: descriptor[cursor...])
                    break
                }
                result.append("<")
                let contentStart = descriptor.index(after: cursor)
                let content = String(descriptor[contentStart..<close])
                result += rewrittenProtocolList(content)
                result.append(">")
                cursor = descriptor.index(after: close)
            }
            return result
        }

        private mutating func rewrittenProtocolList(_ content: String) -> String {
            content.split(separator: ",", omittingEmptySubsequences: false)
                .map { component in
                    let raw = String(component)
                    let leading = raw.prefix { $0.isWhitespace }
                    let trailing = raw.reversed().prefix { $0.isWhitespace }.reversed()
                    let start = raw.index(raw.startIndex, offsetBy: leading.count)
                    let end = raw.index(raw.endIndex, offsetBy: -trailing.count)
                    guard start <= end else { return raw }
                    let protocolName = String(raw[start..<end])
                    guard !protocolName.isEmpty else { return raw }
                    return String(leading)
                        + name(protocolName, expectedKind: .protocol).outputName
                        + String(trailing)
                }
                .joined(separator: ",")
        }

        private mutating func record(_ annotation: Annotation, for rawName: String) {
            if let existing = annotations[rawName] {
                precondition(existing == annotation, "one raw Swift name must have one resolution")
            } else {
                annotations[rawName] = annotation
            }
        }

        private func escapedCString(_ value: String) -> String {
            var result = ""
            for character in value {
                switch character {
                case "\\": result += "\\\\"
                case "\"": result += "\\\""
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                default: result.append(character)
                }
            }
            return result
        }
    }
}
