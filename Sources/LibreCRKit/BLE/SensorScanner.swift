import Foundation
@preconcurrency import CoreBluetooth

#if canImport(CoreBluetooth)

// Async BLE scanner for Libre 3 sensors. Wraps a CBCentralManager and
// surfaces discoveries via an AsyncStream.
//
// Usage:
//   let scanner = SensorScanner()
//   try await scanner.waitUntilReady()
//   for await found in scanner.startScan() {
//       let session = try await scanner.connect(found.peripheral)
//       …
//   }
//
// Permissions: callers must include NSBluetoothAlwaysUsageDescription in
// their Info.plist (the LibreCR app target sets this in project.yml).

public struct DiscoveredSensor: @unchecked Sendable, Hashable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServices: [CBUUID]
    public let advertisementData: [String: String]   // String-summary view
    public let peripheral: CBPeripheral

    public static func == (lhs: DiscoveredSensor, rhs: DiscoveredSensor) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct SensorScannerConfiguration: @unchecked Sendable {
    public let restorationIdentifier: String?
    public let notifyOnConnection: Bool
    public let notifyOnDisconnection: Bool
    public let notifyOnNotification: Bool
    public let discoveryTimeout: TimeInterval

    public init(
        restorationIdentifier: String? = nil,
        notifyOnConnection: Bool = false,
        notifyOnDisconnection: Bool = false,
        notifyOnNotification: Bool = false,
        discoveryTimeout: TimeInterval = 45
    ) {
        self.restorationIdentifier = restorationIdentifier
        self.notifyOnConnection = notifyOnConnection
        self.notifyOnDisconnection = notifyOnDisconnection
        self.notifyOnNotification = notifyOnNotification
        self.discoveryTimeout = discoveryTimeout
    }

    public static let foreground = SensorScannerConfiguration()

    public static func background(restorationIdentifier: String = "org.librecrkit.libre3.central") -> SensorScannerConfiguration {
        SensorScannerConfiguration(
            restorationIdentifier: restorationIdentifier,
            notifyOnConnection: true,
            notifyOnDisconnection: true,
            notifyOnNotification: true
        )
    }

    var centralOptions: [String: Any]? {
        guard let restorationIdentifier else { return nil }
        return [CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier]
    }

    var connectOptions: [String: Any]? {
        var options: [String: Any] = [:]
        if notifyOnConnection {
            options[CBConnectPeripheralOptionNotifyOnConnectionKey] = true
        }
        if notifyOnDisconnection {
            options[CBConnectPeripheralOptionNotifyOnDisconnectionKey] = true
        }
        if notifyOnNotification {
            options[CBConnectPeripheralOptionNotifyOnNotificationKey] = true
        }
        return options.isEmpty ? nil : options
    }
}

public struct SensorConnectionEvent: @unchecked Sendable {
    public let event: CBConnectionEvent
    public let peripheral: CBPeripheral
    public let occurredAt: Date
}

public struct SensorDisconnectionEvent: @unchecked Sendable {
    public let peripheral: CBPeripheral
    public let error: Error?
    public let occurredAt: Date
}

public struct SensorRestorationEvent: @unchecked Sendable {
    public let peripherals: [CBPeripheral]
    public let scanServices: [CBUUID]
    public let scanOptions: [String: String]
}

public enum SensorScannerError: Error, CustomStringConvertible, LocalizedError {
    case bluetoothUnavailable
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case connectionFailed(String)
    case timeout(String)

    public var description: String {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .bluetoothPoweredOff: return "Bluetooth powered off"
        case .bluetoothUnauthorized: return "Bluetooth permission denied"
        case .connectionFailed(let m): return "BLE connect failed: \(m)"
        case .timeout(let m): return "BLE timeout: \(m)"
        }
    }

    public var errorDescription: String? { description }
}

public final class SensorScanner: NSObject, @unchecked Sendable {
    private let configuration: SensorScannerConfiguration
    private let centralQueue = DispatchQueue(label: "re.abbot.librecr.ble", qos: .userInitiated)
    private lazy var central: CBCentralManager = {
        CBCentralManager(delegate: self, queue: centralQueue, options: configuration.centralOptions)
    }()

    private var discoveryContinuation: AsyncStream<DiscoveredSensor>.Continuation?
    private var connectionEventContinuations: [AsyncStream<SensorConnectionEvent>.Continuation] = []
    private var disconnectionEventContinuations: [AsyncStream<SensorDisconnectionEvent>.Continuation] = []
    private var restorationContinuations: [AsyncStream<SensorRestorationEvent>.Continuation] = []
    private var stateEventContinuations: [AsyncStream<CBManagerState>.Continuation] = []
    private var pendingRestorationEvents: [SensorRestorationEvent] = []
    private var stateContinuations: [CheckedContinuation<Void, Error>] = []
    private var pendingConnects: [UUID: PendingConnectBox] = [:]
    private var pendingConnectTimeouts: [UUID: DispatchWorkItem] = [:]
    // Hold strong references to in-flight sessions while they connect.
    private var pendingSessions: [UUID: SensorSession] = [:]
    // Peripherals already logged in the current scan, so a duplicate-allowing
    // scan doesn't flood the log. Reset on every startScan. Mutated on
    // `centralQueue` only.
    private var loggedDiscoveries: Set<UUID> = []

    private final class PendingConnectBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CBPeripheral, Error>?
        private var completed: Result<CBPeripheral, Error>?

        func install(_ continuation: CheckedContinuation<CBPeripheral, Error>) {
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(with: completed)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        @discardableResult
        func resume(with result: Result<CBPeripheral, Error>) -> Bool {
            lock.lock()
            if completed != nil {
                lock.unlock()
                return false
            }
            if let continuation {
                self.continuation = nil
                completed = result
                lock.unlock()
                continuation.resume(with: result)
                return true
            }
            completed = result
            lock.unlock()
            return true
        }

        var isCompleted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed != nil
        }
    }

    public init(configuration: SensorScannerConfiguration = .foreground) {
        self.configuration = configuration
        super.init()
        _ = central  // touch lazy
    }

    /// Suspends until the central manager reports `.poweredOn`, or throws if
    /// the user has denied Bluetooth permission / the radio is off.
    public func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            centralQueue.async {
                if self.central.state == .poweredOn {
                    cont.resume(); return
                }
                if let err = SensorScanner.errorForState(self.central.state) {
                    cont.resume(throwing: err); return
                }
                self.stateContinuations.append(cont)
            }
        }
    }

    /// Starts scanning. By default filters by the Libre 3 service UUID; pass
    /// `nil` to scan for everything (useful for debugging when the sensor
    /// doesn't show up — confirms the radio path and reveals what *is*
    /// advertising nearby).
    public func startScan(
        filter: [CBUUID]? = [LibreSensorGATT.serviceUUID],
        allowDuplicates: Bool = false
    ) -> AsyncStream<DiscoveredSensor> {
        AsyncStream { cont in
            centralQueue.async {
                self.discoveryContinuation = cont
                self.loggedDiscoveries.removeAll()
                let filterDesc = filter?.map { $0.uuidString }.joined(separator: ",") ?? "<all>"
                BLETiming.log("scan.start: filter=[\(filterDesc)] allowDuplicates=\(allowDuplicates)")
                self.central.scanForPeripherals(
                    withServices: filter,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
                )
                cont.onTermination = { _ in
                    self.centralQueue.async { self.central.stopScan() }
                }
            }
        }
    }

    public func stopScan() {
        centralQueue.async {
            BLETiming.log("scan.stop")
            self.central.stopScan()
            self.discoveryContinuation?.finish()
            self.discoveryContinuation = nil
        }
    }

    /// Stream of CoreBluetooth connection events registered through
    /// `registerForConnectionEvents`. An integrating app can use this after a
    /// disconnect to be woken when iOS observes the target peripheral again.
    /// Stream of central-manager state transitions. Yields the current
    /// state immediately on subscribe (so callers don't need to also
    /// poll), then yields again every time `centralManagerDidUpdateState`
    /// fires. Use to drive G7-style "kick reconnect when Bluetooth comes
    /// back on" behavior: subscribe and act on `.poweredOn`.
    public func stateEvents() -> AsyncStream<CBManagerState> {
        AsyncStream { cont in
            centralQueue.async {
                self.stateEventContinuations.append(cont)
                cont.yield(self.central.state)
            }
        }
    }

    public func connectionEvents() -> AsyncStream<SensorConnectionEvent> {
        AsyncStream { cont in
            centralQueue.async {
                self.connectionEventContinuations.append(cont)
            }
        }
    }

    public func disconnectionEvents() -> AsyncStream<SensorDisconnectionEvent> {
        AsyncStream { cont in
            centralQueue.async {
                self.disconnectionEventContinuations.append(cont)
            }
        }
    }

    /// Stream of CoreBluetooth state-restoration callbacks. Apps that use a
    /// restoration identifier must re-create `SensorScanner` early at launch
    /// and then resume sessions for any restored peripherals.
    public func restorationEvents() -> AsyncStream<SensorRestorationEvent> {
        AsyncStream { cont in
            centralQueue.async {
                for event in self.pendingRestorationEvents {
                    cont.yield(event)
                }
                self.pendingRestorationEvents.removeAll()
                self.restorationContinuations.append(cont)
            }
        }
    }

    public func registerForConnectionEvents(
        peripheralIDs: [UUID]? = nil,
        serviceUUIDs: [CBUUID]? = [LibreSensorGATT.serviceUUID]
    ) {
#if os(iOS)
        centralQueue.async {
            var options: [CBConnectionEventMatchingOption: Any] = [:]
            if let peripheralIDs {
                options[.peripheralUUIDs] = peripheralIDs
            }
            if let serviceUUIDs {
                options[.serviceUUIDs] = serviceUUIDs
            }
            self.central.registerForConnectionEvents(options: options.isEmpty ? nil : options)
        }
#else
        _ = peripheralIDs
        _ = serviceUUIDs
#endif
    }

    /// Returns CoreBluetooth peripherals for identifiers remembered by this
    /// installation. This avoids waiting for a scan advertisement when we are
    /// reconnecting to the same sensor after a range loss.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) async -> [CBPeripheral] {
        await withCheckedContinuation { cont in
            centralQueue.async {
                cont.resume(returning: self.central.retrievePeripherals(withIdentifiers: identifiers))
            }
        }
    }

    public func retrieveConnectedPeripherals(serviceUUIDs: [CBUUID] = [LibreSensorGATT.serviceUUID]) async -> [CBPeripheral] {
        await withCheckedContinuation { cont in
            centralQueue.async {
                cont.resume(returning: self.central.retrieveConnectedPeripherals(withServices: serviceUUIDs))
            }
        }
    }

    /// Connects to `peripheral` and returns a fully-discovered `SensorSession`.
    /// The Libre 3 often only accepts connections on roughly minute-spaced
    /// windows, so the default timeout is deliberately longer than one interval.
    public func connect(_ peripheral: CBPeripheral, timeout: TimeInterval = 120) async throws -> SensorSession {
        let connectStart = Date()
        let alreadyConnected: Bool = await withCheckedContinuation { cont in
            centralQueue.async {
                cont.resume(returning: peripheral.state == .connected)
            }
        }
        BLETiming.log(alreadyConnected
                      ? "scanner.connect: peripheral already connected; skipping central.connect"
                      : "scanner.connect: issuing central.connect (state=\(peripheral.state.rawValue))")
        let pendingBox = PendingConnectBox()
        let peripheralID = peripheral.identifier
        let connected: CBPeripheral = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pendingBox.install(cont)
                centralQueue.async {
                    guard !pendingBox.isCompleted else {
                        return
                    }
                    if peripheral.state == .connected {
                        pendingBox.resume(with: .success(peripheral))
                        return
                    }
                    if let existing = self.pendingConnects.removeValue(forKey: peripheralID) {
                        self.pendingConnectTimeouts.removeValue(forKey: peripheralID)?.cancel()
                        self.central.cancelPeripheralConnection(peripheral)
                        existing.resume(with: .failure(
                            SensorScannerError.connectionFailed("superseded by new connect request")
                        ))
                    }
                    self.pendingConnects[peripheralID] = pendingBox
                    if timeout > 0 {
                        let timeoutWork = DispatchWorkItem { [weak self, pendingBox, peripheral] in
                            guard let self else { return }
                            guard self.pendingConnects[peripheralID] === pendingBox else {
                                return
                            }
                            self.pendingConnects.removeValue(forKey: peripheralID)
                            self.pendingConnectTimeouts.removeValue(forKey: peripheralID)
                            self.central.cancelPeripheralConnection(peripheral)
                            pendingBox.resume(with: .failure(
                                SensorScannerError.timeout("connect timed out after \(Int(timeout))s")
                            ))
                        }
                        self.pendingConnectTimeouts[peripheralID] = timeoutWork
                        self.centralQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                    }
                    self.central.connect(peripheral, options: self.configuration.connectOptions)
                }
            }
        } onCancel: {
            self.centralQueue.async {
                if self.pendingConnects[peripheralID] === pendingBox {
                    self.pendingConnects.removeValue(forKey: peripheralID)
                    self.pendingConnectTimeouts.removeValue(forKey: peripheralID)?.cancel()
                    self.central.cancelPeripheralConnection(peripheral)
                }
                pendingBox.resume(with: .failure(CancellationError()))
            }
        }
        let connectMs = Int(Date().timeIntervalSince(connectStart) * 1000)
        BLETiming.log("scanner.connect: didConnect after \(connectMs)ms")
        let session = try await resumeSession(for: connected, timeout: configuration.discoveryTimeout)
        let totalMs = Int(Date().timeIntervalSince(connectStart) * 1000)
        BLETiming.log("scanner.connect: complete (connect+discover+subscribe) in \(totalMs)ms")
        return session
    }

    /// Builds a `SensorSession` around a peripheral restored by CoreBluetooth
    /// and refreshes service discovery / notification state.
    public func resumeSession(
        for peripheral: CBPeripheral,
        timeout: TimeInterval? = nil
    ) async throws -> SensorSession {
        let session = SensorSession(peripheral: peripheral, queue: centralQueue)
        pendingSessions[peripheral.identifier] = session
        do {
            try await session.discoverAndSubscribe(timeout: timeout ?? configuration.discoveryTimeout)
            return session
        } catch {
            pendingSessions.removeValue(forKey: peripheral.identifier)
            throw error
        }
    }

    public func disconnect(_ session: SensorSession) {
        centralQueue.async {
            self.central.cancelPeripheralConnection(session.peripheral)
        }
    }

    /// Read a peripheral's current `CBPeripheralState` from the central
    /// queue. State reads must be queue-synchronized to be reliable
    /// across CB delegate callbacks.
    public func state(of peripheral: CBPeripheral) async -> CBPeripheralState {
        await withCheckedContinuation { cont in
            centralQueue.async {
                cont.resume(returning: peripheral.state)
            }
        }
    }

    /// Best-effort reset of any pending or active connection for this
    /// peripheral so the next `connect` starts from a clean
    /// `.disconnected` state. Use before reconnect to clear out:
    ///   - a `.connecting` from a previously abandoned attempt (pending
    ///     connect that iOS is still holding from a Task we cancelled)
    ///   - a `.connected` that the sensor side has dropped but iOS still
    ///     thinks is alive (phantom-connected)
    ///   - a `.disconnecting` mid-flight tear-down
    ///
    /// Polls the peripheral's state every 100ms (after issuing
    /// `cancelPeripheralConnection`) until it reaches `.disconnected`
    /// or `settleTimeout` elapses. Returns once the state is settled or
    /// the timeout passes — the next connect can proceed either way.
    public func ensureDisconnected(
        peripheralID: UUID,
        settleTimeout: TimeInterval = 2.0
    ) async {
        let peripherals = await retrievePeripherals(withIdentifiers: [peripheralID])
        guard let peripheral = peripherals.first else { return }

        let initial = await state(of: peripheral)
        guard initial != .disconnected else { return }

        await withCheckedContinuation { cont in
            centralQueue.async {
                self.central.cancelPeripheralConnection(peripheral)
                cont.resume()
            }
        }

        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if await state(of: peripheral) == .disconnected { return }
        }
    }

    /// Direct equivalent of `disconnect(_ session:)` for the case where
    /// we only have a peripheral ID (e.g., on reconnect when no session
    /// was ever built). Use `ensureDisconnected` instead unless you need
    /// fire-and-forget semantics.
    public func cancelPeripheralConnection(peripheralID: UUID) async {
        let peripherals = await retrievePeripherals(withIdentifiers: [peripheralID])
        guard let peripheral = peripherals.first else { return }
        await withCheckedContinuation { cont in
            centralQueue.async {
                self.central.cancelPeripheralConnection(peripheral)
                cont.resume()
            }
        }
    }

    // MARK: - Helpers

    static func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .resetting:    return "resetting"
        case .unknown:      return "unknown"
        @unknown default:   return "unknown(\(state.rawValue))"
        }
    }

    /// Normalizes a BLE peripheral name / saved sensor address to a comparable
    /// hex token (hex digits only, upper-cased). Returns `nil` when there are
    /// no hex digits. Shared by the iOS and Watch discovery paths so they match
    /// the saved `bleAddress` against advertised names identically.
    public static func normalizedBLEName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.filter(\.isHexDigit).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func errorForState(_ state: CBManagerState) -> SensorScannerError? {
        switch state {
        case .poweredOff:    return .bluetoothPoweredOff
        case .unauthorized:  return .bluetoothUnauthorized
        case .unsupported:   return .bluetoothUnavailable
        case .resetting, .unknown: return nil
        case .poweredOn:     return nil
        @unknown default:    return .bluetoothUnavailable
        }
    }
}

extension SensorScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BLETiming.log("central.state=\(SensorScanner.stateName(central.state))")
        if central.state == .poweredOn {
            let continuations = stateContinuations
            stateContinuations.removeAll()
            for cont in continuations {
                cont.resume()
            }
        } else if let err = SensorScanner.errorForState(central.state) {
            let continuations = stateContinuations
            stateContinuations.removeAll()
            for cont in continuations {
                cont.resume(throwing: err)
            }
        }
        for cont in stateEventContinuations {
            cont.yield(central.state)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advSummary = advertisementData.reduce(into: [String: String]()) { acc, kv in
            acc[kv.key] = String(describing: kv.value)
        }
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let found = DiscoveredSensor(
            id: peripheral.identifier,
            name: peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String),
            rssi: RSSI.intValue,
            advertisedServices: advertisedServices,
            advertisementData: advSummary,
            peripheral: peripheral
        )
        // Log the first sighting of each peripheral so a field "doesn't find
        // the sensor" report shows exactly what *is* advertising nearby (name,
        // advertised services, signal) without flooding when duplicates are on.
        if loggedDiscoveries.insert(peripheral.identifier).inserted {
            let services = advertisedServices.map { $0.uuidString }.joined(separator: ",")
            BLETiming.log(
                "scan.didDiscover name=\(found.name ?? "nil") " +
                "id=\(peripheral.identifier.uuidString.prefix(8)) rssi=\(RSSI.intValue) " +
                "services=[\(services)]"
            )
        }
        discoveryContinuation?.yield(found)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let pending = pendingConnects.removeValue(forKey: peripheral.identifier) {
            pendingConnectTimeouts.removeValue(forKey: peripheral.identifier)?.cancel()
            pending.resume(with: .success(peripheral))
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BLETiming.log("central.didFailToConnect id=\(peripheral.identifier.uuidString.prefix(8)) error=\(error?.localizedDescription ?? "unknown")")
        if let pending = pendingConnects.removeValue(forKey: peripheral.identifier) {
            pendingConnectTimeouts.removeValue(forKey: peripheral.identifier)?.cancel()
            pending.resume(with: .failure(SensorScannerError.connectionFailed(error?.localizedDescription ?? "unknown")))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        BLETiming.log("central.didDisconnect id=\(peripheral.identifier.uuidString.prefix(8)) error=\(error?.localizedDescription ?? "clean")")
        if let pending = pendingConnects.removeValue(forKey: peripheral.identifier) {
            pendingConnectTimeouts.removeValue(forKey: peripheral.identifier)?.cancel()
            pending.resume(with: .failure(SensorScannerError.connectionFailed(error?.localizedDescription ?? "disconnected")))
        }
        pendingSessions.removeValue(forKey: peripheral.identifier)?.handleDisconnect(error: error)
        let event = SensorDisconnectionEvent(peripheral: peripheral, error: error, occurredAt: Date())
        for cont in disconnectionEventContinuations {
            cont.yield(event)
        }
    }

#if os(iOS)
    public func centralManager(
        _ central: CBCentralManager,
        connectionEventDidOccur event: CBConnectionEvent,
        for peripheral: CBPeripheral
    ) {
        let event = SensorConnectionEvent(event: event, peripheral: peripheral, occurredAt: Date())
        for cont in connectionEventContinuations { cont.yield(event) }
    }
#endif

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let scanServices = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []
        let scanOptions = (dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]) ?? [:]
        let event = SensorRestorationEvent(
            peripherals: peripherals,
            scanServices: scanServices,
            scanOptions: scanOptions.reduce(into: [String: String]()) { out, item in
                out[item.key] = String(describing: item.value)
            }
        )
        if restorationContinuations.isEmpty {
            pendingRestorationEvents.append(event)
        } else {
            for cont in restorationContinuations { cont.yield(event) }
        }
    }
}

// MARK: - High-level discovery

extension SensorScanner {

    /// Tracks the strongest-RSSI candidate seen so far, so a named-target scan
    /// can still hand back a usable peripheral if the exact name never matches
    /// (e.g. the saved address and the advertised name disagree).
    private final class StrongestRSSIBox: @unchecked Sendable {
        private let lock = NSLock()
        private var best: DiscoveredSensor?

        func consider(_ sensor: DiscoveredSensor) {
            lock.lock()
            if let current = best {
                if sensor.rssi > current.rssi { best = sensor }
            } else {
                best = sensor
            }
            lock.unlock()
        }

        func current() -> DiscoveredSensor? {
            lock.lock(); defer { lock.unlock() }
            return best
        }
    }

    /// Discovers the first matching Libre 3 sensor and returns it.
    ///
    /// This is the single discovery entry point shared by the iOS and Watch
    /// apps so both follow identical scan/match/fallback behavior (the
    /// LibreCRKit "one flow" model):
    ///
    /// - Scans filtered by `serviceFilter` (the data-service UUID by default).
    /// - When `targetName` is set, returns the peripheral whose advertised name
    ///   normalizes to the same hex token; otherwise keeps the strongest-RSSI
    ///   candidate as a fallback once a short grace window elapses.
    /// - When `targetName` is `nil` (first-pair), returns the first discovery.
    /// - If `broadScanFallback` is on and a *named* target never appears under
    ///   the service filter, retries with an unfiltered scan matched strictly
    ///   by name. This recovers a Libre 3 that, in its current state, does not
    ///   advertise the data-service UUID — a common cause of "doesn't find."
    public func discoverFirstSensor(
        targetName rawTargetName: String?,
        timeout: TimeInterval,
        serviceFilter: [CBUUID]? = [LibreSensorGATT.serviceUUID],
        broadScanFallback: Bool = true
    ) async throws -> DiscoveredSensor {
        let targetName = SensorScanner.normalizedBLEName(rawTargetName)
        let canBroadFallback = broadScanFallback && targetName != nil
        // Reserve part of the budget for the unfiltered fallback pass when one
        // is possible; otherwise spend the whole budget on the filtered scan.
        let primaryTimeout = canBroadFallback ? max(8, timeout * 0.6) : timeout
        BLETiming.log(
            "discoverFirstSensor: target=\(targetName ?? "<any>") timeout=\(Int(timeout))s " +
            "broadFallback=\(canBroadFallback)"
        )
        do {
            return try await discoverPass(
                targetName: targetName,
                timeout: primaryTimeout,
                serviceFilter: serviceFilter,
                requireNameMatch: false
            )
        } catch let error as SensorScannerError {
            guard canBroadFallback, case .timeout = error, let targetName else { throw error }
            let remaining = max(6, timeout - primaryTimeout)
            BLETiming.log(
                "discoverFirstSensor: service-filtered scan empty; broad-scan fallback " +
                "name=\(targetName) budget=\(Int(remaining))s"
            )
            return try await discoverPass(
                targetName: targetName,
                timeout: remaining,
                serviceFilter: nil,
                requireNameMatch: true
            )
        }
    }

    /// One scan pass. With `requireNameMatch` the strongest-RSSI fallback is
    /// disabled, so an unfiltered scan only ever returns an exact name match
    /// (never an arbitrary nearby BLE device).
    private func discoverPass(
        targetName: String?,
        timeout: TimeInterval,
        serviceFilter: [CBUUID]?,
        requireNameMatch: Bool
    ) async throws -> DiscoveredSensor {
        let fallbackBox = StrongestRSSIBox()
        let fallbackGrace = targetName == nil ? timeout : min(12, max(4, timeout * 0.12))
        let stream = startScan(filter: serviceFilter, allowDuplicates: targetName != nil)
        defer { stopScan() }

        return try await withThrowingTaskGroup(of: DiscoveredSensor.self) { group in
            group.addTask { [stream, targetName, fallbackBox, fallbackGrace, requireNameMatch, timeout] in
                let startedAt = Date()
                for await found in stream {
                    if let targetName {
                        if SensorScanner.normalizedBLEName(found.name) == targetName {
                            return found
                        }
                        if !requireNameMatch {
                            fallbackBox.consider(found)
                            if Date().timeIntervalSince(startedAt) >= fallbackGrace,
                               let best = fallbackBox.current() {
                                return best
                            }
                        }
                        continue
                    }
                    return found
                }
                if !requireNameMatch, let best = fallbackBox.current() { return best }
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }

            group.addTask { [fallbackBox, fallbackGrace, requireNameMatch, timeout] in
                try await Task.sleep(nanoseconds: UInt64(fallbackGrace * 1_000_000_000))
                if !requireNameMatch, let best = fallbackBox.current() { return best }
                let remaining = max(0, timeout - fallbackGrace)
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                if !requireNameMatch, let best = fallbackBox.current() { return best }
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }

            guard let found = try await group.next() else {
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }
            group.cancelAll()
            BLETiming.log(
                "discoverFirstSensor: matched name=\(found.name ?? "nil") " +
                "id=\(found.id.uuidString.prefix(8)) rssi=\(found.rssi) " +
                "filtered=\(serviceFilter != nil)"
            )
            return found
        }
    }
}

#endif
