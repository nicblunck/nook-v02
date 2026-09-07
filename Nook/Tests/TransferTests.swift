import Testing
import NookLibrary
@testable import Nook

@Suite("Object transfers")
struct TransferTests {

    @Test("A drag keeps the selected batch and detects a same-folder drop")
    func selectedBatchCarriesItsSources() {
        let first = ObjectID()
        let second = ObjectID()
        let folder = FolderID()
        let transfer = ObjectTransfer(
            ids: [first, second],
            sourceFolderIDs: [folder, folder]
        )

        #expect(transfer.ids == [first, second])
        #expect(transfer.isAlreadyIn(folder))
        #expect(!transfer.isAlreadyIn(nil))
    }
}
