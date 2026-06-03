import CoreBluetooth
import Foundation
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

    init() {
        loadPersistedState()
        let receiver = WatchSensorStateReceiver { [weak self] data in
            Task { @MainActor [weak self] in
                self?.acceptTransferredState(data)
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
        guard activeSession == nil, connectionTask == nil else {
            return
        }
        reconnect()
    }

    func reconnect() {
        reconnect(preferredPeripheral: nil)
    }

    private func reconnect(preferredPeripheral: CBPeripheral?) {
        guard let sensorState else {
            statusText = "Transferă senzorul din aplicația iPhone"
            return
        }
        if let preferredPeripheral {
            targetPeripheralID = preferredPeripheral.identifier
        }
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        connectionTask?.cancel()
        isConnecting = true
        lastError = nil
        statusText = "Pregătesc conexiunea directă"
        connectionTask = Task { [weak self, sensorState, preferredPeripheral] in
            guard let self else { return }
            defer {
                self.connectionTask = nil
                self.isConnecting = false
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
                try await connectAndListen(to: direct, state: state)
                return
            } catch {
                activeSession = nil
                isConnected = false
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

        statusText = "Autorizez conexiunea"
        let nativeEphemeral = try await Task.detached(priority: .userInitiated) {
            try SessionKey.makeFirstPairNativeEphemeral(entropySource: Self.randomData(count:))
        }.value
        let flow = PairingFlow(
            transport: SensorSessionTransport(session: session),
            phoneCert: try Self.phoneCert(),
            phoneEph: nativeEphemeral.keyPair
        )
        let result = try await flow.runCommandGatedFirstPairHandshake(
            blePIN: state.blePIN,
            maxEntropyAttempts: 1,
            entropySource: { requestedCount in
                try Self.fixedEntropy(nativeEphemeral.nullEntropy11A, requestedCount: requestedCount)
            },
            r2Provider: {
                try Self.randomData(count: 16)
            }
        )
        let crypto = try DataPlaneCrypto(sessionMaterial: result.handshake.sessionMaterial)

        isConnected = true
        reconnectAttempt = 0
        statusText = "Conectat direct la senzor"
        let listener = Task {
            try await self.listenForGlucose(session: session, crypto: crypto)
        }
        do {
            await refreshDataPlaneNotifications(session)
            try await sendHistoricalBootstrap(state: state, session: session, crypto: crypto)
            try await listener.value
        } catch {
            listener.cancel()
            throw error
        }
    }

    private func scheduleReconnect(
        reason: String,
        preferredPeripheral: CBPeripheral? = nil,
        immediate: Bool
    ) {
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
                      self.sensorState != nil,
                      self.activeSession == nil,
                      self.connectionTask == nil else {
                    continue
                }
                self.scheduleReconnect(reason: "bluetooth-powered-on", immediate: true)
            }
        }
    }

    private func firstMatchingDiscovery(targetName: String?, timeout: TimeInterval) async throws -> DiscoveredSensor {
        let timeoutTask = Task { [scanner] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            scanner.stopScan()
        }
        defer {
            timeoutTask.cancel()
            scanner.stopScan()
        }

        for await found in scanner.startScan(filter: [LibreSensorGATT.serviceUUID]) {
            guard targetName == nil || Self.normalizedBLEAddress(found.name) == targetName else {
                continue
            }
            return found
        }
        throw SensorScannerError.timeout("scan timed out after \(Int(timeout))s")
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

    private func acceptTransferredState(_ data: Data) {
        do {
            let state = try Libre3SensorStateLoader.load(fromJSON: data)
            sensorState = state
            hasSensorConfiguration = true
            try Libre3SensorStateLoader.write(state, to: Self.sensorStateURL())
            statusText = "Configurație primită de la iPhone"
            reconnect()
        } catch {
            lastError = "Configurație invalidă: \(error)"
        }
    }

    private func loadPersistedState() {
        if let data = try? Data(contentsOf: Self.sensorStateURL()),
           let state = try? Libre3SensorStateLoader.load(fromJSON: data) {
            sensorState = state
            hasSensorConfiguration = true
            statusText = "Configurație locală disponibilă"
        }
        if let data = try? Data(contentsOf: Self.latestReadingURL()),
           let reading = try? JSONDecoder().decode(WatchGlucoseReading.self, from: data) {
            latestReading = reading
        }
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

    private static func fixedEntropy(_ entropy: Data, requestedCount: Int) throws -> Data {
        guard entropy.count == requestedCount else {
            throw WatchSensorError.invalidEntropyByteCount
        }
        return entropy
    }

    private static func normalizedBLEAddress(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.filter(\.isHexDigit).uppercased()
        return normalized.isEmpty ? nil : normalized
    }
}

private final class WatchSensorStateReceiver: NSObject, WCSessionDelegate {
    private let onStateData: @Sendable (Data) -> Void

    init(onStateData: @escaping @Sendable (Data) -> Void) {
        self.onStateData = onStateData
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

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        accept(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        accept(userInfo)
    }

    private func accept(_ payload: [String: Any]) {
        guard let data = payload["libre3SensorState"] as? Data else {
            return
        }
        onStateData(data)
    }
}

private enum WatchSensorError: Error {
    case notificationStreamEnded
    case phoneCertificateMissing
    case invalidRandomByteCount
    case invalidEntropyByteCount
}
