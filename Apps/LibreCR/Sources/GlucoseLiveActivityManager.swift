import ActivityKit
import AppIntents
import Foundation
import UIKit
import os

@MainActor
final class GlucoseLiveActivityManager {
    static let shared = GlucoseLiveActivityManager()

    private let staleInterval: TimeInterval = 10 * 60
    private var isRequestingActivity = false
    private let log = Logger(subsystem: "org.librecr.app", category: "liveactivity")

    // Diagnostics (timestamps the UI / App Intent can read).
    private(set) var lastGlucoseReceivedAt: Date?
    private(set) var lastUpdateRequestedAt: Date?
    private(set) var lastUpdateCompletedAt: Date?
    private(set) var lastRestartRequestedAt: Date?
    private(set) var lastRestartCompletedAt: Date?

    private init() {}

    private func ts(_ date: Date?) -> String {
        guard let date else { return "—" }
        return ISO8601DateFormatter().string(from: date)
    }

    /// Active (updatable) activity, ignoring ended/dismissed ones so we never
    /// push updates into a dead instance.
    private var activeActivity: Activity<LibreCRGlucoseActivityAttributes>? {
        Activity<LibreCRGlucoseActivityAttributes>.activities.first { $0.activityState == .active }
    }

    var currentActivityID: String? { activeActivity?.id }

    /// Snapshot for the diagnostic intent / debugging: what we last sent to
    /// ActivityKit vs. what the activity currently holds.
    var diagnosticsSummary: String {
        let all = Activity<LibreCRGlucoseActivityAttributes>.activities
        let activity = activeActivity ?? all.first
        let state = activity.map { "\($0.activityState)" } ?? "none"
        let shown = activity.map { ts($0.content.state.updatedAt) } ?? "—"
        return [
            "LiveActivity diagnostics",
            "- activity id: \(activity?.id ?? "none") (\(state))",
            "- activities count: \(all.count)",
            "- activities enabled: \(ActivityAuthorizationInfo().areActivitiesEnabled)",
            "- last glucose received: \(ts(lastGlucoseReceivedAt))",
            "- last restart requested: \(ts(lastRestartRequestedAt))",
            "- last restart completed: \(ts(lastRestartCompletedAt))",
            "- last update requested → ActivityKit: \(ts(lastUpdateRequestedAt))",
            "- last update completed: \(ts(lastUpdateCompletedAt))",
            "- content date held by activity: \(shown)",
        ].joined(separator: "\n")
    }

    private func makeContent(
        latest: StoredGlucoseReading,
        deltaMgDL: Int?
    ) -> ActivityContent<LibreCRGlucoseActivityAttributes.ContentState> {
        let state = LibreCRGlucoseActivityAttributes.ContentState(
            glucoseMgDL: Int(latest.glucoseMgDL),
            deltaMgDL: deltaMgDL,
            trend: latest.trend,
            updatedAt: latest.receivedAt
        )
        return ActivityContent(
            state: state,
            staleDate: latest.receivedAt.addingTimeInterval(staleInterval),
            relevanceScore: 100
        )
    }

    /// Called for every new CGM value (from the reading store). Each call
    /// produces a real `update()` — there is no content-equality filter and no
    /// throttling/debounce here.
    func sync(latest: StoredGlucoseReading, deltaMgDL: Int?) {
        lastGlucoseReceivedAt = latest.receivedAt
        log.info("glucose received mgdl=\(Int(latest.glucoseMgDL), privacy: .public) trend=\(Int(latest.trend), privacy: .public) at=\(self.ts(latest.receivedAt), privacy: .public)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.error("Live Activities disabled by user — skipping update")
            return
        }
        let content = makeContent(latest: latest, deltaMgDL: deltaMgDL)
        Task { @MainActor in
            await self.applyUpdate(
                content: content,
                timestamp: latest.receivedAt,
                sensorName: latest.sensorSerialNumber
            )
        }
    }

    /// Performs the actual ActivityKit update/create. Wrapped in a background
    /// task assertion so a value received during a brief background BLE wake
    /// isn't lost when the process is suspended before the async update runs.
    private func applyUpdate(
        content: ActivityContent<LibreCRGlucoseActivityAttributes.ContentState>,
        timestamp: Date,
        sensorName: String?
    ) async {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityUpdate")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        lastUpdateRequestedAt = Date()
        if let activity = activeActivity {
            log.info("activity update requested id=\(activity.id, privacy: .public) state=active ts=\(self.ts(timestamp), privacy: .public)")
            if #available(iOS 17.2, *) {
                await activity.update(content, timestamp: timestamp)
            } else {
                await activity.update(content)
            }
            lastUpdateCompletedAt = Date()
            log.info("activity update completed id=\(activity.id, privacy: .public) at=\(self.ts(self.lastUpdateCompletedAt), privacy: .public)")
            return
        }

        guard !isRequestingActivity else {
            log.notice("no active activity, request already in flight — skipping")
            return
        }
        isRequestingActivity = true
        defer { isRequestingActivity = false }

        _ = requestNewActivity(content: content, sensorName: sensorName)
    }

    private func requestNewActivity(
        content: ActivityContent<LibreCRGlucoseActivityAttributes.ContentState>,
        sensorName: String?
    ) -> Activity<LibreCRGlucoseActivityAttributes>? {
        let attributes = LibreCRGlucoseActivityAttributes(sensorName: sensorName ?? "Libre 3")
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            lastUpdateCompletedAt = Date()
            log.info("activity created id=\(activity.id, privacy: .public)")
            return activity
        } catch {
            log.error("activity request failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Forces an immediate refresh from the most recent persisted reading,
    /// recreating the activity if none is live. Returns a short status for the
    /// App Intent. Logs the outcome and the current activity id.
    @discardableResult
    func forceRefresh(latest: StoredGlucoseReading?, deltaMgDL: Int?) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.error("forceRefresh: Live Activities disabled")
            return "live-activities-disabled"
        }
        guard let latest else {
            log.notice("forceRefresh: no stored reading to publish")
            return "no-reading-available"
        }
        let existed = activeActivity != nil
        await applyUpdate(
            content: makeContent(latest: latest, deltaMgDL: deltaMgDL),
            timestamp: latest.receivedAt,
            sensorName: latest.sensorSerialNumber
        )
        let id = currentActivityID ?? "none"
        let outcome = existed ? "refreshed id=\(id)" : "recreated id=\(id)"
        log.info("forceRefresh: \(outcome, privacy: .public)")
        return outcome
    }

    /// Restarts the Live Activity instead of updating it. ActivityKit limits a
    /// Live Activity active window to roughly 8 hours; only a new request resets
    /// that window, so the Shortcut/App Intent uses this path.
    @discardableResult
    func restartActivityWindow(latest: StoredGlucoseReading?, deltaMgDL: Int?) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.error("restartActivityWindow: Live Activities disabled")
            return "live-activities-disabled"
        }
        guard let latest else {
            log.notice("restartActivityWindow: no stored reading to publish")
            return "no-reading-available"
        }

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityRestart")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        let content = makeContent(latest: latest, deltaMgDL: deltaMgDL)
        lastRestartRequestedAt = Date()
        lastUpdateRequestedAt = lastRestartRequestedAt

        let existing = Activity<LibreCRGlucoseActivityAttributes>.activities
        log.info("restarting activity window existingCount=\(existing.count, privacy: .public)")
        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard !isRequestingActivity else {
            log.notice("restartActivityWindow: request already in flight")
            return "restart-request-in-flight"
        }
        isRequestingActivity = true
        defer { isRequestingActivity = false }
        let activity = requestNewActivity(
            content: content,
            sensorName: latest.sensorSerialNumber
        )

        guard let activity else {
            return "restart-failed"
        }
        lastRestartCompletedAt = Date()
        let outcome = "restarted id=\(activity.id)"
        log.info("restartActivityWindow: \(outcome, privacy: .public)")
        return outcome
    }

    func end() {
        log.info("ending all activities (count=\(Activity<LibreCRGlucoseActivityAttributes>.activities.count, privacy: .public))")
        Task {
            for activity in Activity<LibreCRGlucoseActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - Shortcuts / App Intent

/// Lets the App Intent kick the live CGM connection without owning any BLE
/// logic. The view model registers a closure that calls its existing reconnect
/// path; the intent just invokes it when the app process is alive.
@MainActor
final class LiveActivityServiceBridge {
    static let shared = LiveActivityServiceBridge()
    private var kick: (@MainActor () -> String)?
    private init() {}

    func register(_ kick: @escaping @MainActor () -> String) { self.kick = kick }
    var isServiceRegistered: Bool { kick != nil }
    func requestServiceStart() -> String? { kick?() }
}

/// Shortcuts-callable intent that ensures the CGM service is running, recreates
/// the glucose Live Activity if missing, and forces an immediate refresh.
///
/// Exposed to Shortcuts via `LibreCRAppShortcuts`. Runs without opening the app
/// (`openAppWhenRun = false`); if the app process isn't running the system
/// launches it in the background to execute `perform()`.
@available(iOS 17.0, *)
struct RestartGlucoseLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Restart Glucose Live Activity"
    static var description = IntentDescription(
        "Ensures the CGM service is running, restarts the glucose Live Activity, and extends the active window."
    )

    private static let log = Logger(subsystem: "org.librecr.app", category: "liveactivity.intent")

    func perform() async throws -> some IntentResult {
        let log = RestartGlucoseLiveActivityIntent.log
        log.info("LiveActivityIntent invoked")

        // 1. Ensure the CGM service is running. If the SwiftUI view model has
        //    not registered yet, initialize the shared model and use the same
        //    saved-state reconnect path.
        let serviceOutcome = await MainActor.run {
            LiveActivityServiceBridge.shared.requestServiceStart()
                ?? NFCActivationViewModel.shared.ensureLiveServiceRunning()
        }
        log.info("service start outcome=\(serviceOutcome, privacy: .public)")

        // 2. Snapshot the latest persisted reading (kept inside one main-actor
        //    hop so the non-Sendable store never crosses actors).
        let snapshot: (latest: StoredGlucoseReading?, delta: Int?) = await MainActor.run {
            let store = GlucoseReadingStore()
            return (store.latest, store.latestDelta)
        }

        // 3. Restart the Live Activity to reset ActivityKit's active window.
        let outcome = await GlucoseLiveActivityManager.shared.restartActivityWindow(
            latest: snapshot.latest,
            deltaMgDL: snapshot.delta
        )
        let activityID = await GlucoseLiveActivityManager.shared.currentActivityID ?? "none"
        log.info("activity \(outcome, privacy: .public) current id=\(activityID, privacy: .public)")

        // Diagnostic dump (last sent vs. content held by the activity).
        let diagnostics = await GlucoseLiveActivityManager.shared.diagnosticsSummary
        log.info("\(diagnostics, privacy: .public)")

        return .result(dialog: "Live Activity \(outcome); service \(serviceOutcome)")
    }
}

struct LibreCRAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RestartGlucoseLiveActivityIntent(),
            phrases: [
                "Refresh \(.applicationName) glucose",
                "Update \(.applicationName) Live Activity",
                "Restart \(.applicationName) Live Activity",
            ],
            shortTitle: "Restart Glucose Live Activity",
            systemImageName: "drop.fill"
        )
    }
}
