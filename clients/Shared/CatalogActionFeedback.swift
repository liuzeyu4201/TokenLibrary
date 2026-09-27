import Foundation

struct CatalogSavedResult<Value> {
    let value: Value
    let refreshError: String?
}

/// A committed local mutation stays successful when its follow-up UI read fails.
/// Callers retry only the read, not the original user action.
@MainActor
enum CatalogActionFeedback {
    static func save<Value>(_ write: () throws -> Value, refresh: () throws -> Void) throws -> CatalogSavedResult<Value> {
        let value = try write()
        do {
            try refresh()
            return CatalogSavedResult(value: value, refreshError: nil)
        } catch {
            return CatalogSavedResult(value: value, refreshError: error.localizedDescription)
        }
    }
}
