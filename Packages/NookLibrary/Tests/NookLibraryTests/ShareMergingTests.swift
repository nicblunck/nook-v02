import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NookLibrary

@Suite("Share merging")
struct ShareMergingTests {

    private func text(_ string: String) -> ResolvedShareItem {
        ResolvedShareItem(importItem: .data(Data(string.utf8), contentType: .plainText, suggestedName: nil))
    }

    private func link(_ string: String) -> ResolvedShareItem {
        ResolvedShareItem(importItem: .link(URL(string: string)!))
    }

    private func textFile(_ string: String) throws -> ResolvedShareItem {
        let directory = URL.temporaryDirectory.appending(path: "ShareMerging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Shared.txt")
        try Data(string.utf8).write(to: url)
        return ResolvedShareItem(importItem: .file(url: url, contentType: .plainText),
                                 temporaryDirectoryURL: directory)
    }

    private func linkURLs(_ merged: [(index: Int, item: ResolvedShareItem)]) -> [String] {
        merged.compactMap {
            if case .link(let url) = $0.item.importItem { return url.absoluteString }
            return nil
        }
    }

    @Test("A link sent again as text is saved once, as the link")
    func linkAndSameLinkAsText() throws {
        let merged = ShareItemResolver.merged([
            link("https://example.com/article"),
            try textFile("https://example.com/article"),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.index == 0)
        #expect(linkURLs(merged) == ["https://example.com/article"])
    }

    @Test("The link the host sent wins over the same address sent first as text")
    func realLinkWinsOverText() {
        let merged = ShareItemResolver.merged([
            text("https://example.com/article/"),
            link("https://example.com/article"),
        ])
        #expect(merged.map(\.index) == [1])
    }

    @Test("A caption mentioning the link is not saved as a text file")
    func captionWithLink() {
        let merged = ShareItemResolver.merged([
            text("Look at this https://example.com/article"),
            link("https://example.com/article"),
        ])
        #expect(merged.map(\.index) == [1])
    }

    @Test("A page title sent beside the link is not saved as a text file")
    func titleBesideLink() {
        let merged = ShareItemResolver.merged([
            link("https://example.com/article"),
            text("An Interesting Article"),
        ])
        #expect(merged.map(\.index) == [0])
    }

    @Test("Text that is only an address becomes a link")
    func addressAsText() {
        let merged = ShareItemResolver.merged([text("  https://example.com/a \n")])
        #expect(linkURLs(merged) == ["https://example.com/a"])
    }

    @Test("Text shared on its own is kept as text")
    func plainTextAlone() {
        let merged = ShareItemResolver.merged([text("A note to self")])
        #expect(merged.count == 1)
        guard case .data = merged.first?.item.importItem else {
            Issue.record("Expected the text to stay text")
            return
        }
    }

    @Test("Two different links are both kept")
    func differentLinks() {
        let merged = ShareItemResolver.merged([
            link("https://example.com/a"),
            link("https://example.com/b"),
        ])
        #expect(merged.count == 2)
    }

    @Test("The same bytes twice are saved once")
    func identicalFiles() throws {
        let merged = ShareItemResolver.merged([
            try textFile("same contents\nacross two lines"),
            try textFile("same contents\nacross two lines"),
        ])
        #expect(merged.map(\.index) == [0])
    }

    @Test("A dropped duplicate's temporary files are removed")
    func droppedFilesAreCleanedUp() throws {
        let duplicate = try textFile("https://example.com/article")
        guard case .file(let url, _) = duplicate.importItem else { return }
        _ = ShareItemResolver.merged([link("https://example.com/article"), duplicate])
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
