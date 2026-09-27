import SwiftUI
import BackgroundTasks
import LibraryCore
import OSLog

@main
struct TokenLibraryApp: App {
    @Environment(\.scenePhase) private var scenePhase
    static let refreshID = "app.tokenlibrary.sync"
    static let processingID = "app.tokenlibrary.sync.processing"
    private static let logger = Logger(subsystem:"app.tokenlibrary",category:"background-sync")
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil) { task in
            let processing = task as! BGProcessingTask
            let work = Task {
                let outcome = await AppModel.synchronizeInBackground(timeBudget: .seconds(170))
                let finished: Bool
                switch outcome {
                case .synchronized, .notConfigured, .noSavedSession: finished = true
                default: finished = false
                }
                processing.setTaskCompleted(success: finished)
            }
            processing.expirationHandler = { work.cancel() }
        }
    }
    var body: some Scene {
        WindowGroup { TokenLibraryRoot() }
            .backgroundTask(.appRefresh(Self.refreshID)) {
                await backgroundSync(timeBudget: .seconds(25))
                Self.scheduleBackgroundSync()
            }
            .onChange(of:scenePhase) { _,phase in
                if phase == .background { Self.scheduleBackgroundSync() }
            }
    }
    nonisolated static func scheduleBackgroundSync() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        for request in [refresh as BGTaskRequest, processing] {
            do { try BGTaskScheduler.shared.submit(request) }
            catch { logger.info("Background sync was not scheduled: \(error.localizedDescription,privacy:.public)") }
        }
    }
    @MainActor private func backgroundSync(timeBudget: Duration) async {
        switch await AppModel.synchronizeInBackground(timeBudget: timeBudget) {
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
