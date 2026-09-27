import SwiftUI
import BackgroundTasks
import LibraryCore
import OSLog

@main
struct TokenLibraryApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private static let refreshID = "app.tokenlibrary.sync"
    private static let logger = Logger(subsystem:"app.tokenlibrary",category:"background-sync")
    var body: some Scene {
        WindowGroup { TokenLibraryRoot() }
            .backgroundTask(.appRefresh(Self.refreshID)) {
                await backgroundSync()
                await scheduleRefresh()
            }
            .onChange(of:scenePhase) { _,phase in
                if phase == .background { scheduleRefresh() }
            }
    }
    private func scheduleRefresh() {
        let request=BGAppRefreshTaskRequest(identifier:Self.refreshID)
        request.earliestBeginDate=Date(timeIntervalSinceNow:15*60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Self.logger.info("Background refresh was not scheduled: \(error.localizedDescription,privacy:.public)") }
    }
    @MainActor private func backgroundSync() async {
        switch await AppModel.synchronizeInBackground() {
        case .synchronized:
            Self.logger.info("Background sync completed.")
        case .cancelled:
            Self.logger.info("Background sync expired; durable progress resumes in foreground.")
        case .notConfigured, .noSavedSession, .configurationChanged:
            Self.logger.info("Background sync has no matching saved connection.")
        case .credentialsUnavailable, .credentialsTimedOut, .requiresLogin:
            Self.logger.info("Background sync requires foreground sign-in or credential access.")
        case .deferred:
            // No credentials or document names in the operational log.
            Self.logger.info("Background sync deferred until the next opportunity.")
        }
    }
}
