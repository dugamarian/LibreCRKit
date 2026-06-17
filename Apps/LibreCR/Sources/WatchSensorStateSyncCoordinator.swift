import Foundation
import LibreCRKit
import WatchConnectivity

final class WatchSensorStateSyncCoordinator: NSObject {
    static let shared = WatchSensorStateSyncCoordinator()

    static let sensorStateKey = "libre3SensorState"
    static let sentAtKey = "sentAt"
    static let schemaVersionKey = "schemaVersion"
    static let directConnectionEnabledKey = "watchDirectConnectionEnabled"
    static let requestStateKey = "requestSensorState"
    static let glucoseKey = "latestGlucose"          // [lifeCount, mgDL, trend, receivedAt]

    private let queue = DispatchQueue(label: "org.librecr.watch-sync")
    private var pendingStateData: Data?
    private var pendingGlucose: [String: Any]?
    private var pendingPreferenceUpdate = false
    private var directConnectionEnabled = false
    private var shouldGuaranteeNextDelivery = false

    /// Invoked (on the main actor) when the counterpart device sends a fresh
    /// glucose reading or a sensor state carrying a Phase 5 key. The app's view
    /// model registers these to mirror the other device's data without owning
    /// any WatchConnectivity logic.
    var onReceivedGlucose: (@Sendable (UInt16, UInt16, UInt8, Date) -> Void)?
    var onReceivedState: (@Sendable (Libre3SensorState) -> Void)?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func publish(_ state: Libre3SensorState, guaranteeDelivery: Bool) {
        guard let data = try? Libre3SensorStateLoader.jsonData(from: state) else {
            return
        }
        queue.async {
            self.pendingStateData = data
            self.shouldGuaranteeNextDelivery = self.shouldGuaranteeNextDelivery || guaranteeDelivery
            self.flushIfPossible()
        }
    }

    func publishDirectConnectionEnabled(_ enabled: Bool, guaranteeDelivery: Bool) {
        queue.async {
            self.directConnectionEnabled = enabled
            self.pendingPreferenceUpdate = true
            self.shouldGuaranteeNextDelivery = self.shouldGuaranteeNextDelivery || guaranteeDelivery
            self.flushIfPossible()
        }
    }

    /// Share the latest glucose reading with the counterpart device (so both
    /// screens show current data regardless of which one is connected).
    func publishGlucose(lifeCount: UInt16, mgDL: UInt16, trend: UInt8, receivedAt: Date) {
        queue.async {
            self.pendingGlucose = [
                "lifeCount": Int(lifeCount),
                "mgDL": Int(mgDL),
                "trend": Int(trend),
                "receivedAt": receivedAt.timeIntervalSince1970,
            ]
            self.flushIfPossible()
        }
    }

    /// Handles anything the counterpart device sends: a state request (re-send
    /// our latest), a fresh glucose reading, or a sensor state (Phase 5 key).
    private func handleIncoming(_ payload: [String: Any]) {
        if payload[Self.requestStateKey] != nil {
            queue.async {
                self.shouldGuaranteeNextDelivery = true
                self.flushIfPossible()
            }
        }
        if let glucose = payload[Self.glucoseKey] as? [String: Any],
           let lc = glucose["lifeCount"] as? Int,
           let mgDL = glucose["mgDL"] as? Int,
           let trend = glucose["trend"] as? Int,
           let ts = glucose["receivedAt"] as? TimeInterval {
            onReceivedGlucose?(UInt16(lc), UInt16(mgDL), UInt8(trend), Date(timeIntervalSince1970: ts))
        }
        if let data = payload[Self.sensorStateKey] as? Data,
           let state = try? Libre3SensorStateLoader.load(fromJSON: data) {
            onReceivedState?(state)
        }
    }

    private func flushIfPossible() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              pendingStateData != nil || pendingPreferenceUpdate || pendingGlucose != nil else {
            return
        }

        var payload: [String: Any] = [
            Self.sentAtKey: Date(),
            Self.schemaVersionKey: 1,
            Self.directConnectionEnabledKey: directConnectionEnabled,
        ]
        if let data = pendingStateData {
            payload[Self.sensorStateKey] = data
        }
        if let glucose = pendingGlucose {
            payload[Self.glucoseKey] = glucose
        }
        do {
            try WCSession.default.updateApplicationContext(payload)
            if shouldGuaranteeNextDelivery {
                WCSession.default.transferUserInfo(payload)
            }
            shouldGuaranteeNextDelivery = false
            pendingPreferenceUpdate = false
        } catch {
            // Keep the latest state queued until WCSession activates again.
        }
    }
}

extension WatchSensorStateSyncCoordinator: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        queue.async {
            self.flushIfPossible()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(applicationContext)
    }
}
