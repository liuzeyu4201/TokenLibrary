import Foundation
import XCTest
@testable import LibraryCore

final class SessionVaultTests: XCTestCase {
    func testAsyncCredentialInstancesRetainNewTokenWhenOldLogoutArrives() async throws {
        guard ProcessInfo.processInfo.environment["TEST_TOKENLIBRARY_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set TEST_TOKENLIBRARY_KEYCHAIN=1 to exercise an isolated temporary Keychain service")
        }
        let vault = SessionVault(service: "TokenLibrary.tests.async.\(UUID().uuidString)")
        let server = URL(string: "https://async-vault-test.invalid")!
        defer { try? vault.delete(server: server) }
        let first = AsyncSessionVault(vault: vault), second = AsyncSessionVault(vault: vault)
        let old = SavedLibrarySession(username: "test", login: LoginResult(sessionToken: "old-test-token", epoch: "epoch", rootId: "root", libraryId: "library", deviceId: "device"))
        let new = SavedLibrarySession(username: "test", login: LoginResult(sessionToken: "new-test-token", epoch: "epoch", rootId: "root", libraryId: "library", deviceId: "device"))
        try await first.save(old, server: server)
        try await second.save(new, server: server)
        try await first.delete(server: server, matchingSessionToken: old.login.sessionToken)
        let retained = try await first.load(server: server)
        XCTAssertEqual(retained, new)
        try await second.delete(server: server, matchingSessionToken: new.login.sessionToken)
        let deleted = try await first.load(server: server)
        XCTAssertNil(deleted)
    }

    func testKeychainSessionRoundTripUpdateIsolationAndDelete() throws {
        guard ProcessInfo.processInfo.environment["TEST_TOKENLIBRARY_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set TEST_TOKENLIBRARY_KEYCHAIN=1 to exercise an isolated temporary Keychain service")
        }
        let vault = SessionVault(service: "TokenLibrary.tests.\(UUID().uuidString)")
        let server = URL(string: "https://vault-test.invalid")!, other = URL(string: "https://other-vault-test.invalid")!
        defer { try? vault.delete(server: server); try? vault.delete(server: other) }
        let login = LoginResult(sessionToken: "temporary-test-token", epoch: "test-epoch", rootId: "test-root", libraryId: "test-library", deviceId: "test-device")
        let first = SavedLibrarySession(username: "first-test-user", login: login)
        XCTAssertNil(try vault.load(server: server))
        try vault.save(first, server: server)
        XCTAssertEqual(try vault.load(server: URL(string: "https://VAULT-TEST.invalid:443/")!), first)
        XCTAssertNil(try vault.load(server: other))
        let updated = SavedLibrarySession(username: "updated-test-user", login: login)
        try vault.save(updated, server: server)
        XCTAssertEqual(try vault.load(server: server), updated)
        XCTAssertEqual(try vault.load(server: server, interactionAllowed: false), updated)
        try vault.delete(server: server)
        XCTAssertNil(try vault.load(server: server))
        try vault.delete(server: server)
    }
}
