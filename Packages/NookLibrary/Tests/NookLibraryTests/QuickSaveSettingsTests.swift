import Foundation
import Testing
@testable import NookLibrary

@Suite("Quick save settings")
struct QuickSaveSettingsTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "nook.tests.quickSave.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Quick saves go to the Inbox until a folder is chosen")
    func defaultsToInbox() {
        #expect(QuickSaveSettings(defaults: freshDefaults()).folderID == nil)
    }

    @Test("A chosen folder is read back by another reader of the same defaults")
    func folderRoundTrips() {
        let defaults = freshDefaults()
        let id = FolderID()

        QuickSaveSettings(defaults: defaults).folderID = id
        #expect(QuickSaveSettings(defaults: defaults).folderID == id)

        QuickSaveSettings(defaults: defaults).folderID = nil
        #expect(QuickSaveSettings(defaults: defaults).folderID == nil)
    }
}
