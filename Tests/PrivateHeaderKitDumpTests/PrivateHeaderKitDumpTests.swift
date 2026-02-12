import Testing

@testable import PrivateHeaderKitDump
import PrivateHeaderKitTooling

@Suite struct PrivateHeaderKitDumpTests {
    @Test func targetFrameworkOnlySelectsFrameworks() throws {
        var args = DumpArguments()
        args.targets = ["SafariShared"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.frameworkNames.contains("safarishared.framework"))
        #expect(selection.dumpAllSystemLibraryExtras == false)
        #expect(selection.systemLibraryItems.isEmpty)
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs.isEmpty)
        #expect(selection.dumpAllFrameworks == false)
        #expect(resolveNestedEnabled(args) == true)
    }

    @Test func targetSystemItemOnlyDoesNotDumpFrameworks() throws {
        var args = DumpArguments()
        args.targets = ["PreferenceBundles/Foo.bundle"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories.isEmpty)
        #expect(selection.dumpAllSystemLibraryExtras == false)
        #expect(selection.systemLibraryItems == ["PreferenceBundles/Foo.bundle"])
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs.isEmpty)
    }

    @Test func targetAllPresetEnablesAllScopes() throws {
        var args = DumpArguments()
        args.targets = ["@all"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.dumpAllSystemLibraryExtras == true)
        #expect(selection.dumpAllUsrLibDylibs == true)
        #expect(selection.dumpAllFrameworks == true)
        #expect(selection.frameworkNames.isEmpty)
    }

    @Test func noNestedDisablesNested() {
        var args = DumpArguments()
        args.targets = ["SafariShared"]
        args.nested = false
        #expect(resolveNestedEnabled(args) == false)
    }

    @Test func legacyScopeAllEqualsAllPreset() throws {
        var args = DumpArguments()
        args.scope = .all

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.dumpAllSystemLibraryExtras == true)
        #expect(selection.dumpAllUsrLibDylibs == true)
    }

    @Test func targetUsrLibDylibParsesName() throws {
        var args = DumpArguments()
        args.targets = ["/usr/lib/libobjc.A.dylib"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories.isEmpty)
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs == ["libobjc.A.dylib"])
    }

    @Test func systemLibraryTargetRejectsDotDotComponents() {
        let targets = [
            "../Foo.bundle",
            "PreferenceBundles/../Foo.bundle",
            "./Foo.bundle",
            "PreferenceBundles/./Foo.bundle",
        ]
        for target in targets {
            var args = DumpArguments()
            args.targets = [target]
            do {
                _ = try buildDumpSelection(args)
                #expect(Bool(false))
            } catch let error as ToolingError {
                guard case .invalidArgument = error else {
                    #expect(Bool(false))
                    continue
                }
            } catch {
                #expect(Bool(false))
            }
        }
    }
}
