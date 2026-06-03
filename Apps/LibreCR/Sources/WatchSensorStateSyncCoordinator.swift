import Foundation
import LibreCRKit
import WatchConnectivity

final class WatchSensorStateSyncCoordinator: NSObject {
    static let shared = WatchSensorStateSyncCoordinator()

    static let sensorStateKey = "libre3SensorState"
    static let sentAtKey = "sentAt"
    static let schemaVersionKey = "schemaVersion"

    private let queue = DispatchQueue(label: "org.librecr.watch-sync")
    private var pendingStateData: Data?
    private var shouldGuaranteeNextDelivery = false

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

    private func flushIfPossible() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let data = pendingStateData else {
            return
        }

        let payload: [String: Any] = [
            Self.sensorStateKey: data,
            Self.sentAtKey: Date(),
            Self.schemaVersionKey: 1,
        ]
        do {
            try WCSession.default.updateApplicationContext(payload)
            if shouldGuaranteeNextDelivery {
                WCSession.default.transferUserInfo(payload)
            }
            shouldGuaranteeNextDelivery = false
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
}
