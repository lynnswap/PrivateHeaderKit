import Foundation
import ObjCDump
import Testing
@testable import PrivateHeaderKitRawDumpCore
#if canImport(ObjectiveC) && canImport(PrivateHeaderKitRawDumpRuntimeObjC)
import ObjectiveC
import PrivateHeaderKitRawDumpRuntimeObjC
#endif

@Suite
struct SwiftObjCNameResolverTests {
    @Test func resolvesSupportedLegacyTypeShapes() throws {
        let topLevel = try resolved("_TtC4Demo3Foo")
        #expect(topLevel.displayName == "Demo.Foo")
        #expect(topLevel.kind == .class)
        #expect(topLevel.source == .objcRuntimeName)
        #expect(topLevel.objcIdentifier.hasPrefix("PHKSwift__Demo_Foo__"))
        #expect(topLevel.fileStem == "Demo.Foo")

        let nested = try resolved("_TtCC4Demo6Parent5Child")
        #expect(nested.displayName == "Demo.Parent.Child")

        let generic = try resolved(
            "_TtGC18PhotosIntelligence12AssetElectorCSo8PHPerson_"
        )
        #expect(generic.displayName == "PhotosIntelligence.AssetElector<__C.PHPerson>")
        #expect(generic.fileStem.contains("PhotosIntelligence.AssetElector"))

        let privateType = try resolved(
            "_TtC33AppleMediaServicesUIPaymentSheetsP33_03AA647FCA97033A1DFDB2F3E86BC43E19ResourceBundleClass"
        )
        let otherPrivateType = try resolved(
            "_TtC33AppleMediaServicesUIPaymentSheetsP33_13AA647FCA97033A1DFDB2F3E86BC43E19ResourceBundleClass"
        )
        #expect(privateType.displayName.contains("ResourceBundleClass"))
        #expect(privateType.displayName.contains("03AA647FCA97033A1DFDB2F3E86BC43E"))
        #expect(otherPrivateType.displayName.contains("13AA647FCA97033A1DFDB2F3E86BC43E"))
        #expect(otherPrivateType.objcIdentifier != privateType.objcIdentifier)

        let localType = try resolved(
            "_TtCFIZvE14VoiceShortcutsCSo8NSBundle8_currentS0_iU_FT_S0_L_2__"
        )
        #expect(localType.displayName.contains("closure #1"))
        #expect(localType.objcIdentifier.hasPrefix("PHKSwift__"))

        let `protocol` = try resolved("_TtP4Demo5Proto_")
        #expect(`protocol`.displayName == "Demo.Proto")
        #expect(`protocol`.kind == .protocol)
    }

    @Test func metadataSymbolAndRuntimeNameShareCanonicalAlias() throws {
        let runtime = try resolved("_TtC4Demo3Foo")
        let metadata = try resolved("_$s4Demo3FooCN")

        #expect(metadata.source == .classMetadataSymbol)
        #expect(metadata.displayName == runtime.displayName)
        #expect(metadata.canonicalName == runtime.canonicalName)
        #expect(metadata.objcIdentifier == runtime.objcIdentifier)
        #expect(runtime.canonicalName != "class:Demo.Foo")
        #expect(runtime.canonicalName.contains("node:"))
        #expect(runtime.canonicalName.utf8.count > runtime.displayName.utf8.count)

        let genericRuntime = try resolved("_TtGC4Demo3BoxSi_")
        let genericMetadata = try resolved("_$s4Demo3BoxCySiGN")
        #expect(genericMetadata.displayName == "Demo.Box<Swift.Int>")
        #expect(genericMetadata.canonicalName == genericRuntime.canonicalName)
        #expect(genericMetadata.objcIdentifier == genericRuntime.objcIdentifier)
    }

    @Test func runtimeQualifiedNamesAcceptUnicodeNestedAndGenericPresentation() throws {
        for displayName in ["デモ.可視", "Demo.Outer.Inner", "Demo.Box<Swift.Int>"] {
            guard case .resolved(let resolved) =
                SwiftObjCNameResolver.resolveRuntimeOriginClassName(displayName)
            else {
                throw SwiftObjCHeaderRenderingTestError.expectedResolvedName(displayName)
            }
            #expect(resolved.source == .runtimeQualifiedName)
            #expect(resolved.displayName == displayName)
            #expect(resolved.objcIdentifier.hasPrefix("PHKSwift__"))
            #expect(resolved.objcIdentifier.unicodeScalars.allSatisfy { $0.isASCII })
        }

        for rejected in ["Demo..Foo", "Demo. Foo", "Demo/Foo", "Demo\\Foo", "Demo.\0Foo"] {
            #expect(
                SwiftObjCNameResolver.resolveRuntimeOriginClassName(rejected) == .notSwift
            )
        }
    }

    @Test func rejectsNonTypeAndMalformedSwiftMarkersVisibly() {
        #expect(
            SwiftObjCNameResolver.resolve("$s4Demo3fooyyF")
                == .unavailable(rawName: "$s4Demo3fooyyF")
        )
        #expect(
            SwiftObjCNameResolver.resolve("_TtNotAType")
                == .unavailable(rawName: "_TtNotAType")
        )
        #expect(SwiftObjCNameResolver.resolve("_Zi") == .notSwift)
        #expect(SwiftObjCNameResolver.resolve("NSObject") == .notSwift)
    }

    @Test func aliasesAreASCIIIdentifiersAndBounded() throws {
        let resolved = try resolved(
            "_TtGC19SiriContactsIntents17BaseIntentHandlerCS_16GetContactIntentCS_24GetContactIntentResponseCS_37GetContactSiriMatchesResolutionResult_"
        )

        #expect(resolved.objcIdentifier.utf8.count <= 128)
        #expect(resolved.objcIdentifier.first?.isLetter == true)
        #expect(
            resolved.objcIdentifier.unicodeScalars.allSatisfy {
                $0.isASCII
                    && (($0.value >= 48 && $0.value <= 57)
                        || ($0.value >= 65 && $0.value <= 90)
                        || ($0.value >= 97 && $0.value <= 122)
                        || $0 == "_")
            }
        )
        #expect(resolved.fileStem.utf8.count <= 200)
    }

    private func resolved(_ rawName: String) throws -> ResolvedSwiftObjCName {
        guard case .resolved(let resolved) = SwiftObjCNameResolver.resolve(rawName) else {
            throw SwiftObjCHeaderRenderingTestError.expectedResolvedName(rawName)
        }
        return resolved
    }
}

@Suite
struct SwiftObjCClassSelectionTests {
    @Test func runtimeOnlySupplementsMissingRawIdentity() {
        let sharedRawName = "_TtC4Demo3Foo"
        let staticInfo = makeClassInfo(
            name: sharedRawName,
            ivars: [ObjCIvarInfo(name: "staticOnly", typeEncoding: "@", offset: 0)]
        )
        let runtimeInfo = makeClassInfo(
            name: sharedRawName,
            ivars: [ObjCIvarInfo(name: "runtimeOnly", typeEncoding: "@", offset: 0)]
        )
        let runtimeOnly = makeClassInfo(name: "_TtC4Demo3Bar")
        var classInfos = [staticInfo.name: staticInfo]

        supplementMissingRuntimeClassInfos(
            [runtimeInfo, runtimeOnly],
            into: &classInfos
        )

        #expect(classInfos.count == 2)
        #expect(classInfos[sharedRawName] == staticInfo)
        #expect(classInfos[runtimeOnly.name] == runtimeOnly)
    }

    @Test func qualifiedRuntimeOriginMatchesStaticMangledIdentity() {
        let staticInfo = makeClassInfo(
            name: "_TtC4Demo3Foo",
            ivars: [ObjCIvarInfo(name: "staticOnly", typeEncoding: "@", offset: 0)]
        )
        let runtimeInfo = makeClassInfo(
            name: "Demo.Foo",
            ivars: [ObjCIvarInfo(name: "runtimeOnly", typeEncoding: "@", offset: 0)]
        )
        var classInfos = [staticInfo.name: staticInfo]

        let inserted = supplementMissingRuntimeClassInfos([runtimeInfo], into: &classInfos)

        #expect(inserted.isEmpty)
        #expect(classInfos == [staticInfo.name: staticInfo])
    }

    @Test func runtimeLogicalDuplicatesPreferRawSpellingRegardlessOfInputOrder() {
        let raw = makeClassInfo(name: "_TtC4Demo3Foo")
        let qualified = makeClassInfo(name: "Demo.Foo")
        var first: [String: ObjCClassInfo] = [:]
        var second: [String: ObjCClassInfo] = [:]

        let firstInserted = supplementMissingRuntimeClassInfos(
            [qualified, raw],
            into: &first
        )
        let secondInserted = supplementMissingRuntimeClassInfos(
            [raw, qualified],
            into: &second
        )

        #expect(first == [raw.name: raw])
        #expect(second == first)
        #expect(firstInserted == [raw.name])
        #expect(secondInserted == firstInserted)
    }
}

@Suite
struct SwiftObjCHeaderProjectionTests {
    @Test func projectsEveryRenderedTypeReferenceWithSortedMappings() throws {
        let foo = "_TtC4Demo3Foo"
        let bar = "_TtC4Demo3Bar"
        let baz = "_TtC4Demo3Baz"
        let proto = "_TtP4Demo5Proto_"
        let info = makeClassInfo(
            name: foo,
            superClassName: bar,
            protocols: [makeProtocolInfo(name: proto)],
            ivars: [
                ObjCIvarInfo(name: "_Zi", typeEncoding: "@\"\(baz)\"", offset: 0),
                ObjCIvarInfo(
                    name: "composition",
                    typeEncoding: "@\"NativeRoot<\(proto)>\"",
                    offset: 8
                ),
            ],
            properties: [
                ObjCPropertyInfo(
                    name: "$state",
                    attributesString: "T@\"\(baz)\",&,N,V_state",
                    isClassProperty: false
                )
            ],
            methods: [
                ObjCMethodInfo(
                    name: "convert:",
                    typeEncoding: "@\"\(baz)\"24@0:8@\"\(bar)\"16",
                    isClassMethod: false,
                    imp: 0
                )
            ]
        )

        let entry = SwiftObjCHeaderRendering.classEntry(info)
        let fooName = try resolved(foo)
        let barName = try resolved(bar)
        let bazName = try resolved(baz)
        let protoName = try resolved(proto)

        #expect(entry.rawIdentity == foo)
        #expect(entry.displayBaseName == "Demo.Foo")
        #expect(entry.headerString.contains("@interface \(fooName.objcIdentifier) : \(barName.objcIdentifier) <\(protoName.objcIdentifier)>"))
        #expect(entry.headerString.contains("\(bazName.objcIdentifier) *_Zi;"))
        #expect(entry.headerString.contains("NativeRoot<\(protoName.objcIdentifier)> *composition;"))
        #expect(entry.headerString.contains("@property(retain, nonatomic) \(bazName.objcIdentifier) *$state;"))
        #expect(entry.headerString.contains("- (\(bazName.objcIdentifier) *)convert:(\(barName.objcIdentifier) *)arg0;"))
        #expect(entry.headerString.contains("_Zi"))
        #expect(entry.headerString.contains("$state"))

        let commentLines = entry.headerString.split(separator: "\n").prefix {
            $0.hasPrefix("// Swift name:")
        }.map(String.init)
        var expectedComments: [String] = []
        for rawName in [foo, bar, baz, proto].sorted() {
            let displayName = try resolved(rawName).displayName
            expectedComments.append("// Swift name: \(rawName) -> \(displayName)")
        }
        #expect(commentLines == expectedComments)
        #expect(
            entry.headerString.contains(
                "__attribute__((objc_runtime_name(\"\(foo)\")))\n@interface"
            )
        )
    }

    @Test func ordinaryObjectiveCHeaderIsByteForByteUnchanged() {
        let info = makeClassInfo(
            name: "NativeClass",
            superClassName: "NativeBase",
            ivars: [ObjCIvarInfo(name: "_Zi", typeEncoding: "@\"NativeValue\"", offset: 0)]
        )

        let entry = SwiftObjCHeaderRendering.classEntry(info)

        #expect(entry.displayBaseName == info.name)
        #expect(entry.headerString == info.headerString)
    }

    @Test func malformedSwiftNameRemainsRawAndVisible() {
        let rawName = "_TtNotAType"
        let info = makeClassInfo(name: rawName)

        let entry = SwiftObjCHeaderRendering.classEntry(info)

        #expect(entry.displayBaseName == rawName)
        #expect(entry.headerString.hasPrefix("// Swift name unavailable: \(rawName)\n"))
        #expect(entry.headerString.contains("@interface \(rawName)"))
        #expect(!entry.headerString.contains("objc_runtime_name"))
    }

    @Test func protocolOwnNameCarriesRuntimeAttribute() throws {
        let rawName = "_TtP4Demo5Proto_"
        let info = makeProtocolInfo(name: rawName)
        let resolved = try resolved(rawName)

        let entry = SwiftObjCHeaderRendering.protocolEntry(info)

        #expect(entry.displayBaseName == "Demo.Proto")
        #expect(entry.headerString.contains("@protocol \(resolved.objcIdentifier)"))
        #expect(
            entry.headerString.contains(
                "__attribute__((objc_runtime_name(\"\(rawName)\")))\n@protocol"
            )
        )
        #expect(!entry.headerString.contains("Objective-C runtime binding unavailable"))
    }

    @Test func categoryMetadataSymbolUsesAliasWithoutRuntimeAttribute() throws {
        let metadataSymbol = "_$s4Demo3FooCN"
        let resolved = try resolved(metadataSymbol)
        let info = ObjCCategoryInfo(
            name: "Extras",
            className: metadataSymbol,
            protocols: [],
            classProperties: [],
            properties: [],
            classMethods: [],
            methods: []
        )

        let entry = SwiftObjCHeaderRendering.categoryEntry(info)

        #expect(entry.displayBaseName.hasPrefix("Demo.Foo+Extras"))
        #expect(entry.headerString.contains("@interface \(resolved.objcIdentifier) (Extras)"))
        #expect(!entry.headerString.contains("objc_runtime_name"))
        #expect(
            entry.headerString.contains(
                "// Objective-C runtime binding unavailable: \(metadataSymbol)"
            )
        )
    }

    @Test func runtimeOnlyQualifiedNameUsesAliasWithoutUnprovenRuntimeAttribute() throws {
        let qualifiedName = "Demo.Foo"
        guard case .resolved(let qualified) =
            SwiftObjCNameResolver.resolveRuntimeOriginClassName(qualifiedName)
        else {
            throw SwiftObjCHeaderRenderingTestError.expectedResolvedName(qualifiedName)
        }
        let mangled = try resolved("_TtC4Demo3Foo")

        let entry = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(name: qualifiedName),
            runtimeOrigin: true
        )

        #expect(qualified.objcIdentifier == mangled.objcIdentifier)
        #expect(qualified.canonicalName != mangled.canonicalName)
        #expect(entry.displayBaseName == "Demo.Foo")
        #expect(entry.headerString.hasPrefix("// Swift name: Demo.Foo -> Demo.Foo\n"))
        #expect(entry.headerString.contains("@interface \(mangled.objcIdentifier)"))
        #expect(!entry.headerString.contains("objc_runtime_name"))
        #expect(
            entry.headerString.contains(
                "// Objective-C runtime binding unavailable: Demo.Foo"
            )
        )
    }

    @Test func unicodeRuntimeQualifiedNameNeverLeaksIntoObjectiveCDeclaration() throws {
        let qualifiedName = "デモ.可視"
        guard case .resolved(let resolved) =
            SwiftObjCNameResolver.resolveRuntimeOriginClassName(qualifiedName)
        else {
            throw SwiftObjCHeaderRenderingTestError.expectedResolvedName(qualifiedName)
        }

        let entry = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(name: qualifiedName),
            runtimeOrigin: true
        )

        #expect(entry.headerString.contains("@interface \(resolved.objcIdentifier)"))
        #expect(!entry.headerString.contains("@interface \(qualifiedName)"))
        #expect(entry.headerString.contains("// Swift name: \(qualifiedName) -> \(qualifiedName)"))
        #expect(
            entry.headerString.contains(
                "// Objective-C runtime binding unavailable: \(qualifiedName)"
            )
        )
    }

    @Test func rawIdentityDeterminesCollisionSuffixAndInputOrderDoesNot() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            ObjCHeaderEntry(
                symbolKind: .class,
                rawIdentity: "_TtC4Demo3Foo",
                displayBaseName: "Demo.Foo",
                headerString: "first"
            ),
            ObjCHeaderEntry(
                symbolKind: .class,
                rawIdentity: "_$s4Demo3FooCN",
                displayBaseName: "Demo.Foo",
                headerString: "second"
            ),
        ]

        let first = resolveObjCHeaderEntries(entries, options: options)
        let second = resolveObjCHeaderEntries(Array(entries.reversed()), options: options)

        #expect(first == second)
        #expect(Set(first.map(\.fileName)).count == 2)
        #expect(first.allSatisfy { $0.fileName.hasPrefix("Demo.Foo~") })
    }

    #if os(macOS)
    @Test func generatedAliasGraphParsesAsObjectiveC() throws {
        let nativeRoot = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(name: "NativeRoot")
        )
        let proto = SwiftObjCHeaderRendering.protocolEntry(
            makeProtocolInfo(name: "_TtP4Demo5Proto_")
        )
        let bar = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(name: "_TtC4Demo3Bar")
        )
        let baz = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(name: "_TtC4Demo3Baz")
        )
        let foo = SwiftObjCHeaderRendering.classEntry(
            makeClassInfo(
                name: "_TtC4Demo3Foo",
                superClassName: "_TtC4Demo3Bar",
                protocols: [makeProtocolInfo(name: "_TtP4Demo5Proto_")],
                ivars: [
                    ObjCIvarInfo(
                        name: "value",
                        typeEncoding: "@\"_TtC4Demo3Baz\"",
                        offset: 0
                    ),
                    ObjCIvarInfo(
                        name: "composition",
                        typeEncoding: "@\"NativeRoot<_TtP4Demo5Proto_>\"",
                        offset: 8
                    ),
                ],
                properties: [
                    ObjCPropertyInfo(
                        name: "value",
                        attributesString: "T@\"_TtC4Demo3Baz\",&,N,Vvalue",
                        isClassProperty: false
                    )
                ],
                methods: [
                    ObjCMethodInfo(
                        name: "convert:",
                        typeEncoding: "@\"_TtC4Demo3Baz\"24@0:8@\"_TtC4Demo3Bar\"16",
                        isClassMethod: false,
                        imp: 0
                    )
                ]
            )
        )
        let source = [
            nativeRoot.headerString,
            proto.headerString,
            bar.headerString,
            baz.headerString,
            foo.headerString,
        ]
            .joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-fsyntax-only", "-Wno-objc-root-class", "-x", "objective-c", "-"]
        let input = Pipe()
        let diagnostics = Pipe()
        process.standardInput = input
        process.standardError = diagnostics
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let diagnosticText = String(
            data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0, Comment(rawValue: diagnosticText))
    }
    #endif

    private func resolved(_ rawName: String) throws -> ResolvedSwiftObjCName {
        guard case .resolved(let resolved) = SwiftObjCNameResolver.resolve(rawName) else {
            throw SwiftObjCHeaderRenderingTestError.expectedResolvedName(rawName)
        }
        return resolved
    }
}

#if canImport(ObjectiveC) && canImport(PrivateHeaderKitRawDumpRuntimeObjC)
class RuntimeNameBaseFixture: NSObject {}
final class RuntimeNameChildFixture: RuntimeNameBaseFixture {}
private final class PrivateRuntimeNameFixture: NSObject {}

@Suite
struct SwiftObjCRuntimeIdentityTests {
    @Test func inspectorUsesClassAndSuperclassRuntimeAPINames() throws {
        var failedStage: NSString?
        let snapshot = try #require(
            PHRuntimeObjCInspector.snapshot(
                for: RuntimeNameChildFixture.self,
                failedStage: &failedStage
            )
        )
        let rawName = String(cString: class_getName(RuntimeNameChildFixture.self))
        let superclassRawName = String(cString: class_getName(RuntimeNameBaseFixture.self))

        #expect(failedStage == nil)
        #expect(snapshot.objcRuntimeName == rawName)
        #expect(snapshot.superclassObjCRuntimeName == superclassRawName)
        #expect(snapshot.objcRuntimeName == NSStringFromClass(RuntimeNameChildFixture.self))
    }

    @Test func inspectorPreservesPrivateRuntimeSpelling() throws {
        var failedStage: NSString?
        let snapshot = try #require(
            PHRuntimeObjCInspector.snapshot(
                for: PrivateRuntimeNameFixture.self,
                failedStage: &failedStage
            )
        )
        let rawName = String(cString: class_getName(PrivateRuntimeNameFixture.self))

        #expect(failedStage == nil)
        #expect(snapshot.objcRuntimeName == rawName)
        #expect(rawName.hasPrefix("_Tt"))
    }
}
#endif

private enum SwiftObjCHeaderRenderingTestError: Error {
    case expectedResolvedName(String)
}

private func makeClassInfo(
    name: String,
    superClassName: String? = nil,
    protocols: [ObjCProtocolInfo] = [],
    ivars: [ObjCIvarInfo] = [],
    classProperties: [ObjCPropertyInfo] = [],
    properties: [ObjCPropertyInfo] = [],
    classMethods: [ObjCMethodInfo] = [],
    methods: [ObjCMethodInfo] = []
) -> ObjCClassInfo {
    ObjCClassInfo(
        name: name,
        version: 0,
        imageName: nil,
        instanceSize: 0,
        superClassName: superClassName,
        protocols: protocols,
        ivars: ivars,
        classProperties: classProperties,
        properties: properties,
        classMethods: classMethods,
        methods: methods
    )
}

private func makeProtocolInfo(name: String) -> ObjCProtocolInfo {
    ObjCProtocolInfo(
        name: name,
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
