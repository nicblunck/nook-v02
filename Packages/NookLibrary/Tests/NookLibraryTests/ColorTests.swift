import Foundation
import Testing
@testable import NookLibrary

@Suite("Colors")
struct ColorTests {

    @Test("Hex codes are read in the forms they are copied in, and nothing else is")
    func colorCodes() {
        #expect(ColorCode.normalized("#ff6b35") == "#FF6B35")
        #expect(ColorCode.normalized("  #F63\n") == "#FF6633")
        // No #, and it could as easily be a word or a number.
        #expect(ColorCode.normalized("facade") == nil)
        #expect(ColorCode.normalized("123456") == nil)
        #expect(ColorCode.normalized("#12345") == nil)
        #expect(ColorCode.normalized("#GGGGGG") == nil)

        #expect(ColorCode.codes(in: "#FF6B35, #004E89\n#fff") == ["#FF6B35", "#004E89", "#FFFFFF"])
        // A sentence that mentions a colour is text, not a palette.
        #expect(ColorCode.codes(in: "Use #FF6B35 for buttons") == nil)
        #expect(ColorCode.codes(in: "   ") == nil)
    }

    @Test("A pasted code becomes a colour chip, which keeps its colour when renamed")
    func importsAColor() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let report = await harness.service.importItems([.color(hex: "#ff6b35")], into: .root)
        let id = try #require(report.importedIDs.first)
        let object = try #require(await harness.service.object(id))
        #expect(object.kind == .color)
        #expect(object.title == "#FF6B35")
        #expect(object.colorHex == "#FF6B35")

        try await harness.service.updateObject(id, title: "Brand Orange")
        #expect(await harness.service.object(id)?.colorHex == "#FF6B35")
    }
}
