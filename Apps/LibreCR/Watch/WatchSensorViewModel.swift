import CoreBluetooth
import Foundation
#if os(watchOS)
import HealthKit
#endif
import LibreCRKit
import SwiftUI
import WatchConnectivity

struct WatchGlucoseReading: Codable, Equatable {
    let lifeCount: UInt16
    let glucoseMgDL: UInt16
    let trend: UInt8
    let receivedAt: Date

    var trendSymbol: String {
        switch trend {
        case 1: return "arrow.down"
        case 2: return "arrow.down.right"
        case 3: return "arrow.right"
        case 4: return "arrow.up.right"
        case 5: return "arrow.up"
        default: return "questionmark"
        }
    }

    var trendLabel: String {
        switch trend {
        case 1: return "Scade rapid"
        case 2: return "În scădere"
        case 3: return "Stabil"
        case 4: return "În creștere"
        case 5: return "Crește rapid"
        default: return "Trend indisponibil"
        }
    }

    var trendColor: Color {
        switch trend {
        case 1, 5: return .red
        case 2, 4: return .orange
        case 3: return .green
        default: return .secondary
        }
    }
}

@MainActor
final class WatchSensorViewModel: ObservableObject {
    @Published private(set) var statusText = "Aștept configurația senzorului"
    @Published private(set) var lastError: String?
    @Published private(set) var latestReading: WatchGlucoseReading?
    @Published private(set) var previousReading: WatchGlucoseReading?
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasSensorConfiguration = false
    @Published private(set) var directConnectionEnabled = false
    @Published private(set) var workoutModeActive = false
    @Published private(set) var workoutModeStarting = false
    @Published private(set) var workoutModeStatus = "AOD oprit"

    private let scanner = SensorScanner(
        configuration: SensorScannerConfiguration(
            restorationIdentifier: "org.librecr.watch.central",
            notifyOnConnection: true,
            notifyOnDisconnection: true,
            notifyOnNotification: true
        )
    )
    private var receiver: WatchSensorStateReceiver?
    private var sensorState: Libre3SensorState?
    private var activeSession: SensorSession?
    private var targetPeripheralID: UUID?
    private var connectionTask: Task<Void, Never>?
    private var reconnectRetryTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var connectionGeneration = 0
    private let enableFastCachedReconnect = ProcessInfo.processInfo.arguments.contains("--fast-cached-reconnect")
    #if os(watchOS)
    private var workoutAODController: WatchWorkoutAODController?
    #endif

    private final class DiscoveryFallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var best: DiscoveredSensor?

        func consider(_ sensor: DiscoveredSensor) {
            lock.lock()
            if let current = best {
                if sensor.rssi > current.rssi {
                    best = sensor
                }
            } else {
                best = sensor
            }
            lock.unlock()
        }

        func current() -> DiscoveredSensor? {
            lock.lock()
            defer { lock.unlock() }
            return best
        }
    }

    nonisolated fileprivate static let sensorStatePayloadKey = "libre3SensorState"
    nonisolated fileprivate static let directConnectionEnabledPayloadKey = "watchDirectConnectionEnabled"
    nonisolated fileprivate static let directConnectionEnabledDefaultsKey = "LibreCRWatchDirectConnectionEnabled"

    init() {
        loadPersistedState()
        let receiver = WatchSensorStateReceiver { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.acceptTransferredPayload(payload)
            }
        }
        self.receiver = receiver
        receiver.activate()
        observeScannerLifecycle()
        reconnectIfNeeded()
    }

    var deltaText: String {
        guard let latestReading, let previousReading else {
            return "--"
        }
        return String(format: "%+d", Int(latestReading.glucoseMgDL) - Int(previousReading.glucoseMgDL))
    }

    func reconnectIfNeeded() {
        guard directConnectionEnabled else {
            if hasSensorConfiguration {
                statusText = "Conexiunea directă e oprită pe iPhone"
            }
            return
        }
        guard activeSession == nil, connectionTask == nil else {
            return
        }
        reconnect()
    }

    func reconnect() {
        reconnect(preferredPeripheral: nil)
    }

    func setWorkoutModeEnabled(_ enabled: Bool) {
        if enabled {
            startWorkoutMode()
        } else {
            stopWorkoutMode()
        }
    }

    private func startWorkoutMode() {
        guard !workoutModeActive, !workoutModeStarting else {
            return
        }
        #if os(watchOS)
        workoutModeStarting = true
        workoutModeStatus = "Pornesc AOD"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.workoutModeStarting = false
            }
            do {
                try await self.aodWorkoutController().start()
                self.workoutModeActive = true
                self.workoutModeStatus = "AOD workout activ"
            } catch {
                self.workoutModeActive = false
                self.workoutModeStatus = "AOD indisponibil"
                self.lastError = "AOD workout: \(error)"
            }
        }
        #else
        workoutModeActive = false
        workoutModeStarting = false
        workoutModeStatus = "AOD disponibil doar pe Apple Watch"
        #endif
    }

    private func stopWorkoutMode() {
        #if os(watchOS)
        workoutAODController?.stop()
        workoutAODController = nil
        #endif
        workoutModeStarting = false
        workoutModeActive = false
        workoutModeStatus = "AOD oprit"
    }

    #if os(watchOS)
    private func aodWorkoutController() -> WatchWorkoutAODController {
        if let workoutAODController {
            return workoutAODController
        }
        let controller = WatchWorkoutAODController { [weak self] state, error in
            Task { @MainActor [weak self] in
                self?.handleWorkoutAODState(state, error: error)
            }
        }
        workoutAODController = controller
        return controller
    }

    private func handleWorkoutAODState(_ state: HKWorkoutSessionState, error: Error?) {
        if let error {
            workoutModeActive = false
            workoutModeStarting = false
            workoutModeStatus = "AOD oprit"
            lastError = "AOD workout: \(error)"
            return
        }

        switch state {
        case .running:
            workoutModeActive = true
            workoutModeStarting = false
            workoutModeStatus = "AOD workout activ"
        case .ended, .stopped:
            workoutModeActive = false
            workoutModeStarting = false
            workoutModeStatus = "AOD oprit"
        case .paused:
            workoutModeActive = true
            workoutModeStarting = false
            workoutModeStatus = "AOD workout pauzat"
        case .notStarted, .prepared:
            workoutModeStatus = workoutModeStarting ? "Pornesc AOD" : "AOD pregătit"
        @unknown default:
            workoutModeStatus = "AOD stare necunoscută"
        }
    }
    #endif

    private func reconnect(preferredPeripheral: CBPeripheral?) {
        guard directConnectionEnabled else {
            stopDirectConnection(reason: "disabled-by-phone")
            return
        }
        guard let sensorState else {
            statusText = "Transferă senzorul din aplicația iPhone"
            return
        }
        if let preferredPeripheral {
            targetPeripheralID = preferredPeripheral.identifier
        }
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil

        let previousSession = activeSession
        activeSession = nil
        isConnected = false

        connectionTask?.cancel()
        connectionGeneration += 1
        let generation = connectionGeneration
        isConnecting = true
        lastError = nil
        statusText = "Pregătesc conexiunea directă"
        connectionTask = Task { @MainActor [weak self, sensorState, preferredPeripheral] in
            guard let self else { return }
            defer {
                if self.connectionGeneration == generation {
                    self.connectionTask = nil
                    self.isConnecting = false
                }
            }

            if let previousSession {
                previousSession.handleDisconnect(error: nil)
                self.scanner.disconnect(previousSession)
                await self.scanner.ensureDisconnected(
                    peripheralID: previousSession.peripheral.identifier
                )
            }

            do {
                try await self.runDirectSensorConnection(
                    state: sensorState,
                    preferredPeripheral: preferredPeripheral
                )
            } catch is CancellationError {
                self.statusText = "Conexiune oprită"
            } catch {
                self.isConnected = false
                self.activeSession = nil
                self.lastError = String(describing: error)
                self.statusText = "Conexiune pierdută; reprogramez"
                self.scheduleReconnect(reason: "connection-ended", immediate: false)
            }
        }
    }

    private func runDirectSensorConnection(
        state: Libre3SensorState,
        preferredPeripheral: CBPeripheral?
    ) async throws {
        try await scanner.waitUntilReady()
        let targetName = Self.normalizedBLEAddress(state.bleAddress)

        let directPeripheral: CBPeripheral?
        if let preferredPeripheral {
            directPeripheral = preferredPeripheral
        } else {
            directPeripheral = await reconnectPeripheral(targetName: targetName)
        }

        if let direct = directPeripheral {
            do {
                statusText = "Reconectez senzorul Libre 3"
                if preferredPeripheral == nil {
                    let directState = await scanner.state(of: direct)
                    if directState != .disconnected {
                        await scanner.ensureDisconnected(peripheralID: direct.identifier)
                    }
                }
                try await connectAndListen(to: direct, state: state)
                return
            } catch {
                await scanner.ensureDisconnected(peripheralID: direct.identifier)
                statusText = "Reconectarea directă a eșuat; caut senzorul"
                lastError = String(describing: error)
            }
        }

        statusText = "Caut senzorul Libre 3"
        let discovered = try await firstMatchingDiscovery(
            targetName: targetName,
            timeout: 150
        )
        try await connectAndListen(to: discovered.peripheral, state: state)
    }

    private func connectAndListen(to peripheral: CBPeripheral, state: Libre3SensorState) async throws {
        statusText = "Conectez senzorul"
        let session = try await scanner.connect(peripheral, timeout: 150)
        activeSession = session
        targetPeripheralID = session.peripheral.identifier

        do {
            statusText = "Autorizez conexiunea"
            let sessionMaterial = try await authorize(session: session, state: state)
            let crypto = try DataPlaneCrypto(sessionMaterial: sessionMaterial)

            isConnected = true
            reconnectAttempt = 0
            statusText = "Conectat direct la senzor"
            let listener = Task { @MainActor in
                try await self.listenForGlucose(session: session, crypto: crypto)
            }
            do {
                await refreshDataPlaneNotifications(session)
                try await sendHistoricalBootstrap(state: self.sensorState ?? state, session: session, crypto: crypto)
                try await listener.value
            } catch {
                listener.cancel()
                throw error
            }
        } catch {
            activeSession = nil
            isConnected = false
            session.handleDisconnect(error: error)
            scanner.disconnect(session)
            await scanner.ensureDisconnected(peripheralID: session.peripheral.identifier)
            throw error
        }
    }

    private func authorize(session: SensorSession, state: Libre3SensorState) async throws -> Phase6SessionMaterial {
        if enableFastCachedReconnect, let phase5RawKey = state.phase5RawKey {
            statusText = "Autorizez conexiunea salvată rapid"
            let flow = PairingFlow(
                transport: SensorSessionTransport(session: session)
            )
            let result = try await Self.withTimeout(seconds: 35, label: "cached authorization") {
                try await flow.runCachedReconnectHandshake(
                    tail4: state.blePIN,
                    phase5RawKey: phase5RawKey,
                    r2Provider: {
                        try Self.randomData(count: 16)
                    },
                    commandTimeout: 2,
                    notifyTimeout: 12
                )
            }
            return result.sessionMaterial
        }

        if let phase5RawKey = state.phase5RawKey {
            statusText = "Autorizez conexiunea salvată"
            let nativeEphemeral = try await Task.detached(priority: .userInitiated) {
                try SessionKey.makeFirstPairNativeEphemeral(entropySource: Self.randomData(count:))
            }.value
            let flow = PairingFlow(
                transport: SensorSessionTransport(session: session),
                phoneCert: try Self.phoneCert(),
                phoneEph: nativeEphemeral.keyPair
            )
            let result = try await Self.withTimeout(seconds: 35, label: "saved authorization") {
                try await flow.runCommandGatedAuthorizationHandshake(
                    tail4: state.blePIN,
                    phase5RawKeyProvider: { _ in phase5RawKey },
                    r2Provider: {
                        try Self.randomData(count: 16)
                    },
                    commandTimeout: 2,
                    notifyTimeout: 12
                )
            }
            return result.sessionMaterial
        }

        statusText = "Autorizez conexiunea inițială"
        let nativeEphemeral = try await Task.detached(priority: .userInitiated) {
            try SessionKey.makeFirstPairNativeEphemeral(entropySource: Self.randomData(count:))
        }.value
        let flow = PairingFlow(
            transport: SensorSessionTransport(session: session),
            phoneCert: try Self.phoneCert(),
            phoneEph: nativeEphemeral.keyPair
        )
        let result = try await Self.withTimeout(seconds: 35, label: "authorization") {
            try await flow.runCommandGatedFirstPairHandshake(
                blePIN: state.blePIN,
                maxEntropyAttempts: 1,
                entropySource: { requestedCount in
                    try Self.fixedEntropy(nativeEphemeral.nullEntropy11A, requestedCount: requestedCount)
                },
                r2Provider: {
                    try Self.randomData(count: 16)
                },
                commandTimeout: 2,
                notifyTimeout: 12
            )
        }
        persistPhase5RawKey(result.phase5Material.rawKey, for: state)
        return result.handshake.sessionMaterial
    }

    private func scheduleReconnect(
        reason: String,
        preferredPeripheral: CBPeripheral? = nil,
        immediate: Bool
    ) {
        guard directConnectionEnabled else {
            statusText = "Conexiunea directă e oprită pe iPhone"
            return
        }
        guard sensorState != nil else {
            return
        }
        if let preferredPeripheral {
            targetPeripheralID = preferredPeripheral.identifier
        }
        guard reconnectRetryTask == nil else {
            statusText = "Reconectare deja programată"
            return
        }
        reconnectAttempt += 1
        let delay = immediate ? 0 : Self.reconnectDelay(forAttempt: reconnectAttempt)
        statusText = delay > 0
            ? "Reconectez în \(Int(delay))s"
            : "Reconectez acum"
        reconnectRetryTask = Task { @MainActor [weak self, preferredPeripheral] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.reconnectRetryTask = nil
            self.lastError = nil
            self.statusText = "Reconectez (\(reason))"
            self.reconnect(preferredPeripheral: preferredPeripheral)
        }
    }

    nonisolated private static func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ..<2:
            return 0
        case 2:
            return 10
        case 3:
            return 30
        default:
            return 60
        }
    }

    private func reconnectPeripheral(targetName: String?) async -> CBPeripheral? {
        if let id = targetPeripheralID {
            let retrieved = await scanner.retrievePeripherals(withIdentifiers: [id])
            if let peripheral = retrieved.first {
                return peripheral
            }
        }

        let connected = await scanner.retrieveConnectedPeripherals()
        if let targetName {
            return connected.first { Self.normalizedBLEAddress($0.name) == targetName }
        }
        return connected.first
    }

    private func observeScannerLifecycle() {
        Task { [weak self] in
            guard let self else { return }
            for await event in self.scanner.restorationEvents() {
                guard let peripheral = event.peripherals.first else {
                    continue
                }
                self.targetPeripheralID = peripheral.identifier
                self.statusText = "Bluetooth restaurat; reconectez"
                self.scheduleReconnect(
                    reason: "central-restore",
                    preferredPeripheral: peripheral,
                    immediate: true
                )
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await state in self.scanner.stateEvents() {
                guard state == .poweredOn,
                      self.directConnectionEnabled,
                      self.sensorState != nil,
                      self.activeSession == nil,
                      self.connectionTask == nil else {
                    continue
                }
                self.scheduleReconnect(reason: "bluetooth-powered-on", immediate: true)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await event in self.scanner.disconnectionEvents() {
                let targetName = Self.normalizedBLEAddress(self.sensorState?.bleAddress)
                let trackedByID = event.peripheral.identifier == self.targetPeripheralID
                let trackedByName =
                    targetName != nil &&
                    Self.normalizedBLEAddress(event.peripheral.name) == targetName
                guard trackedByID || trackedByName else {
                    continue
                }
                self.activeSession = nil
                self.isConnected = false
                self.statusText = "Conexiune pierdută; reconectez"
                self.scheduleReconnect(
                    reason: "did-disconnect",
                    preferredPeripheral: event.peripheral,
                    immediate: false
                )
            }
        }
    }

    private func firstMatchingDiscovery(targetName: String?, timeout: TimeInterval) async throws -> DiscoveredSensor {
        let fallbackBox = DiscoveryFallbackBox()
        let fallbackGrace = targetName == nil ? timeout : min(12, max(4, timeout * 0.12))
        let stream = scanner.startScan(
            filter: [LibreSensorGATT.serviceUUID],
            allowDuplicates: targetName != nil
        )
        defer {
            scanner.stopScan()
        }

        return try await withThrowingTaskGroup(of: DiscoveredSensor.self) { group in
            group.addTask { [stream, targetName, fallbackBox, fallbackGrace] in
                let startedAt = Date()
                for await found in stream {
                    if let targetName {
                        if Self.normalizedBLEAddress(found.name) == targetName {
                            return found
                        }
                        fallbackBox.consider(found)
                        if Date().timeIntervalSince(startedAt) >= fallbackGrace,
                           let fallback = fallbackBox.current() {
                            return fallback
                        }
                        continue
                    }
                    return found
                }
                if let fallback = fallbackBox.current() {
                    return fallback
                }
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }

            group.addTask { [fallbackBox, fallbackGrace, timeout] in
                try await Task.sleep(nanoseconds: UInt64(fallbackGrace * 1_000_000_000))
                if let fallback = fallbackBox.current() {
                    return fallback
                }
                let remaining = max(0, timeout - fallbackGrace)
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                if let fallback = fallbackBox.current() {
                    return fallback
                }
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }

            guard let found = try await group.next() else {
                throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
            }
            group.cancelAll()
            return found
        }
    }

    private func refreshDataPlaneNotifications(_ session: SensorSession) async {
        let order = [
            LibreSensorGATT.Char.glucoseData,
            LibreSensorGATT.Char.patchStatus,
            LibreSensorGATT.Char.historicData,
            LibreSensorGATT.Char.clinicalData,
            LibreSensorGATT.Char.eventLog,
            LibreSensorGATT.Char.factoryData,
            LibreSensorGATT.Char.patchControl,
        ]
        for uuid in order {
            guard await session.isConnected() else {
                return
            }
            try? await session.rearmNotifyBestEffort(for: uuid)
        }
    }

    private func sendHistoricalBootstrap(
        state: Libre3SensorState,
        session: SensorSession,
        crypto: DataPlaneCrypto
    ) async throws {
        let overlap: UInt16 = 10
        let saved = state.lastGlucoseLifeCount ?? overlap
        let lifeCount = saved > overlap ? saved - overlap : 0
        let command = PatchControlCommand.historicalBackfillGreaterEqual(lifeCount: lifeCount)
        let frame = try crypto.encrypt(
            plaintext: command.plaintext,
            sequence: 0x0001,
            kind: .patchControlWrite
        )
        try await session.writeRaw(
            frame.raw,
            to: LibreSensorGATT.Char.patchControl,
            timeout: 10
        )
    }

    private func listenForGlucose(session: SensorSession, crypto: DataPlaneCrypto) async throws {
        let assembler = DataPlaneNotificationAssembler()
        let decoder = DataPlaneDecoder(crypto: crypto)
        for await event in session.notifications() {
            guard let channel = DataPlaneChannel(uuidString: event.characteristic.uuidString),
                  let raw = assembler.feed(fragment: event.fragment, channel: channel),
                  let frame = try? DataFrame.parse(raw),
                  let packet = try? decoder.decrypt(frame: frame, channel: channel) else {
                continue
            }
            if case .realtimeGlucose(let glucose) = packet.payload,
               glucose.isCurrentGlucoseUsable,
               let mgDL = glucose.currentGlucoseMgDL {
                record(
                    WatchGlucoseReading(
                        lifeCount: glucose.lifeCount,
                        glucoseMgDL: mgDL,
                        trend: glucose.trend,
                        receivedAt: event.receivedAt
                    )
                )
            }
        }
        throw WatchSensorError.notificationStreamEnded
    }

    private func record(_ reading: WatchGlucoseReading) {
        guard latestReading?.lifeCount != reading.lifeCount else {
            return
        }
        previousReading = latestReading
        latestReading = reading
        persistReading(reading)
        if let state = sensorState,
           let updated = try? state.updatingLastGlucose(lifeCount: reading.lifeCount, mgDL: reading.glucoseMgDL) {
            sensorState = updated
            try? Libre3SensorStateLoader.write(updated, to: Self.sensorStateURL())
        }
    }

    private func persistPhase5RawKey(_ rawKey: Data, for state: Libre3SensorState) {
        do {
            let updated = try state.updatingPhase5RawKey(rawKey)
            sensorState = updated
            hasSensorConfiguration = true
            try Libre3SensorStateLoader.write(updated, to: Self.sensorStateURL())
            statusText = "Cheie salvată pentru reconectare"
        } catch {
            lastError = "Salvare cheie Phase 5: \(error)"
        }
    }

    private func acceptTransferredPayload(_ payload: WatchSensorSyncPayload) {
        if let enabled = payload.directConnectionEnabled {
            setDirectConnectionEnabled(enabled)
        }

        var acceptedState = false
        if let data = payload.sensorStateData {
            do {
                var state = try Libre3SensorStateLoader.load(fromJSON: data)
                if state.phase5RawKey == nil,
                   let existing = sensorState,
                   let existingPhase5RawKey = existing.phase5RawKey,
                   Self.isSameSensor(state, existing) {
                    state = try state.updatingPhase5RawKey(existingPhase5RawKey)
                }
                sensorState = state
                hasSensorConfiguration = true
                try Libre3SensorStateLoader.write(state, to: Self.sensorStateURL())
                statusText = directConnectionEnabled
                    ? "Configurație primită de la iPhone"
                    : "Configurație primită; conexiunea directă e oprită"
                acceptedState = true
            } catch {
                lastError = "Configurație invalidă: \(error)"
            }
        }

        if directConnectionEnabled, acceptedState || activeSession == nil {
            reconnect()
        } else if !directConnectionEnabled {
            stopDirectConnection(reason: "disabled-by-phone")
        }
    }

    nonisolated private static func isSameSensor(_ lhs: Libre3SensorState, _ rhs: Libre3SensorState) -> Bool {
        if let lhsSerial = lhs.serialNumber, let rhsSerial = rhs.serialNumber {
            return lhsSerial == rhsSerial
        }
        if let lhsAddress = normalizedBLEAddress(lhs.bleAddress),
           let rhsAddress = normalizedBLEAddress(rhs.bleAddress) {
            return lhsAddress == rhsAddress
        }
        return lhs.blePIN == rhs.blePIN
    }

    private func loadPersistedState() {
        directConnectionEnabled = UserDefaults.standard.bool(
            forKey: Self.directConnectionEnabledDefaultsKey
        )
        if let data = try? Data(contentsOf: Self.sensorStateURL()),
           let state = try? Libre3SensorStateLoader.load(fromJSON: data) {
            sensorState = state
            hasSensorConfiguration = true
            statusText = directConnectionEnabled
                ? "Configurație locală disponibilă"
                : "Conexiunea directă e oprită pe iPhone"
        }
        if let data = try? Data(contentsOf: Self.latestReadingURL()),
           let reading = try? JSONDecoder().decode(WatchGlucoseReading.self, from: data) {
            latestReading = reading
        }
    }

    private func setDirectConnectionEnabled(_ enabled: Bool) {
        guard directConnectionEnabled != enabled else {
            return
        }
        directConnectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.directConnectionEnabledDefaultsKey)
        if enabled {
            statusText = hasSensorConfiguration
                ? "Conexiune directă activată pe iPhone"
                : "Aștept configurația senzorului"
            reconnectIfNeeded()
        } else {
            stopDirectConnection(reason: "disabled-by-phone")
        }
    }

    private func stopDirectConnection(reason: String) {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration += 1
        isConnecting = false
        if let session = activeSession {
            session.handleDisconnect(error: nil)
            scanner.disconnect(session)
        }
        activeSession = nil
        isConnected = false
        statusText = reason == "disabled-by-phone"
            ? "Conexiunea directă e oprită pe iPhone"
            : "Conexiune directă oprită"
    }

    private func persistReading(_ reading: WatchGlucoseReading) {
        guard let data = try? JSONEncoder().encode(reading) else {
            return
        }
        try? data.write(to: Self.latestReadingURL(), options: .atomic)
    }

    private static func supportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("LibreCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sensorStateURL() -> URL {
        supportDirectory().appendingPathComponent("Libre3SensorState.json")
    }

    private static func latestReadingURL() -> URL {
        supportDirectory().appendingPathComponent("LatestGlucose.json")
    }

    private static func phoneCert() throws -> PhoneCert {
        guard let url = Bundle.main.url(forResource: "phone_cert_162b", withExtension: "bin") else {
            throw WatchSensorError.phoneCertificateMissing
        }
        return try PhoneCert(raw: Data(contentsOf: url))
    }

    nonisolated private static func randomData(count: Int) throws -> Data {
        guard count >= 0 else {
            throw WatchSensorError.invalidRandomByteCount
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    nonisolated private static func fixedEntropy(_ entropy: Data, requestedCount: Int) throws -> Data {
        guard entropy.count == requestedCount else {
            throw WatchSensorError.invalidEntropyByteCount
        }
        return entropy
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        label: String,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer {
                group.cancelAll()
            }
            group.addTask {
                try await operation()
            }
            group.addTask {
                let boundedSeconds = max(0, seconds)
                try await Task.sleep(nanoseconds: UInt64(boundedSeconds * 1_000_000_000))
                throw WatchSensorError.operationTimedOut(label: label, seconds: boundedSeconds)
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    nonisolated private static func normalizedBLEAddress(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.filter(\.isHexDigit).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    deinit {
        #if os(watchOS)
        workoutAODController?.stop()
        #endif
    }
}

#if os(watchOS)
private final class WatchWorkoutAODController: NSObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private let onStateChange: @Sendable (HKWorkoutSessionState, Error?) -> Void
    private var session: HKWorkoutSession?

    init(onStateChange: @escaping @Sendable (HKWorkoutSessionState, Error?) -> Void) {
        self.onStateChange = onStateChange
        super.init()
    }

    func start() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WatchWorkoutAODError.healthDataUnavailable
        }
        guard session == nil else {
            return
        }

        try await requestWorkoutAuthorization()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        let workoutSession = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        workoutSession.delegate = self
        session = workoutSession
        workoutSession.startActivity(with: Date())
    }

    func stop() {
        session?.end()
        session = nil
    }

    private func requestWorkoutAuthorization() async throws {
        let workoutType = HKObjectType.workoutType()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [workoutType], read: []) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WatchWorkoutAODError.authorizationDenied)
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        onStateChange(toState, nil)
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onStateChange(workoutSession.state, error)
    }
}

private enum WatchWorkoutAODError: Error {
    case healthDataUnavailable
    case authorizationDenied
}
#endif

private struct WatchSensorSyncPayload: Sendable {
    let sensorStateData: Data?
    let directConnectionEnabled: Bool?
}

private final class WatchSensorStateReceiver: NSObject, WCSessionDelegate {
    private let onPayload: @Sendable (WatchSensorSyncPayload) -> Void

    init(onPayload: @escaping @Sendable (WatchSensorSyncPayload) -> Void) {
        self.onPayload = onPayload
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        accept(session.receivedApplicationContext)
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        accept(session.receivedApplicationContext)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        accept(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        accept(userInfo)
    }

    private func accept(_ payload: [String: Any]) {
        let stateData = payload[WatchSensorViewModel.sensorStatePayloadKey] as? Data
        let directConnectionEnabled =
            payload[WatchSensorViewModel.directConnectionEnabledPayloadKey] as? Bool
        guard stateData != nil || directConnectionEnabled != nil else {
            return
        }
        onPayload(
            WatchSensorSyncPayload(
                sensorStateData: stateData,
                directConnectionEnabled: directConnectionEnabled
            )
        )
    }
}

private enum WatchSensorError: Error {
    case notificationStreamEnded
    case phoneCertificateMissing
    case invalidRandomByteCount
    case invalidEntropyByteCount
    case operationTimedOut(label: String, seconds: TimeInterval)
}
