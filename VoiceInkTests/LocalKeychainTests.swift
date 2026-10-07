import Foundation
import Testing
@testable import VoiceInk

#if LOCAL_BUILD
struct LocalKeychainTests {
    @Test func localBuildCanPersistCredentials() throws {
        let key = "VoiceInkTests.local.\(UUID().uuidString)"
        let keychain = KeychainService.shared
        defer { keychain.delete(forKey: key) }

        #expect(keychain.save("test-credential", forKey: key))
        #expect(keychain.getString(forKey: key) == "test-credential")
        #expect(keychain.exists(forKey: key))
        #expect(keychain.save("updated-credential", forKey: key))
        #expect(keychain.getString(forKey: key) == "updated-credential")
        #expect(keychain.delete(forKey: key))
        #expect(!keychain.exists(forKey: key))
    }
}
#endif
