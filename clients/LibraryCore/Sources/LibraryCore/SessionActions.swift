import Foundation

extension SyncClient {
    /// Local Keychain removal belongs to the app. This confirms server revocation.
    public func logoutSession() async throws {
        let response=try await requestJSON(path:"/api/v1/auth/logout",method:"POST",body:.object([:]),retry:false)
        guard response["loggedOut"]?.bool == true else { throw SyncFailure.invalidResponse }
        sessionToken=nil
    }
}
