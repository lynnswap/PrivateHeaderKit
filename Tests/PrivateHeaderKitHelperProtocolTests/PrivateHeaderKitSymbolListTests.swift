import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

struct PrivateHeaderKitSymbolListTests {
    @Test func tsvRoundTripsNamesAndImagePathsWithoutAddresses() throws {
        let list = PrivateHeaderKitSymbolList(
            imagePath: "/System/Library/Foo\tBar\nBaz\\Thing\r",
            symbols: [
                .init(name: "_foo", demangledName: "_foo", visibility: .export),
                .init(name: "__Z3fooi", demangledName: "foo(int)\t\\\n\r", visibility: .local),
            ]
        )
        #expect(try PrivateHeaderKitSymbolList(tsv: list.tsv) == list)
        #expect(list.tsv.split(separator: "\n").count == 4)
        #expect(list.tsv.contains("export\t_foo\t_foo\n"))
    }

    @Test func emptyImageHasAReadableEmptyList() throws {
        let list = PrivateHeaderKitSymbolList(imagePath: "/empty", symbols: [])
        #expect(try PrivateHeaderKitSymbolList(tsv: list.tsv) == list)
        #expect(try PrivateHeaderKitSymbolList(tsv: String(list.tsv.dropLast())) == list)
    }

    @Test(arguments: [
        "not a symbol list",
        "# image\t/Foo\nvisibility\tname\tdemangled_name\nunknown\tx\tx\n",
        "# image\t/Foo\nvisibility\tname\tdemangled_name\nlocal\tx\n",
        "# image\t/Foo\nvisibility\tname\tdemangled_name\nlocal\tx\tbad\\q\n",
    ]) func invalidListsReportAnError(_ text: String) {
        #expect(throws: PrivateHeaderKitSymbolList.ParseError.self) {
            try PrivateHeaderKitSymbolList(tsv: text)
        }
    }
}
