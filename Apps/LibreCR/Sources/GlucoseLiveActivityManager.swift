import ActivityKit
import Foundation

@MainActor
final class GlucoseLiveActivityManager {
    static let shared = GlucoseLiveActivityManager()

    private let staleInterval: TimeInterval = 10 * 60
    private var isRequestingActivity = false

    private init() {}

    func sync(latest: StoredGlucoseReading, deltaMgDL: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let state = LibreCRGlucoseActivityAttributes.ContentState(
            glucoseMgDL: Int(latest.glucoseMgDL),
            deltaMgDL: deltaMgDL,
            trend: latest.trend,
            updatedAt: latest.receivedAt
        )
        let content = ActivityContent(
            state: state,
            staleDate: latest.receivedAt.addingTimeInterval(staleInterval)
        )

        Task { @MainActor in
            if let activity = Activity<LibreCRGlucoseActivityAttributes>.activities.first {
                if #available(iOS 17.2, *) {
                    await activity.update(content, timestamp: latest.receivedAt)
                } else {
                    await activity.update(content)
                }
                return
            }

            guard !isRequestingActivity else {
                return
            }
            isRequestingActivity = true
            defer { isRequestingActivity = false }

            let attributes = LibreCRGlucoseActivityAttributes(
                sensorName: latest.sensorSerialNumber ?? "Libre 3"
            )
            _ = try? Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        }
    }

    func end() {
        Task {
            for activity in Activity<LibreCRGlucoseActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
