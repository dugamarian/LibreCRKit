import SwiftUI
import Security
@preconcurrency import CoreBluetooth
import LibreCRKit
#if canImport(UIKit)
import UIKit
#endif

struct NFCActivationView: View {
    @ObservedObject var model: NFCActivationViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingManualImport =
        ProcessInfo.processInfo.arguments.contains("--show-manual-sensor-import")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusRow
                    receiverSection
                    controls
                    decodedDataSection
                    connectionSection
                    watchSection
                    persistenceSection
                    patchSection
                    activationSection
                    bleHandoffSection
                    lifecycleSection
                    if let error = model.lastError {
                        Divider()
                        Text("Error").font(.headline).foregroundStyle(.red)
                        Text(error).font(.caption).textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle("NFC")
        }
        .sheet(isPresented: $showingManualImport) {
            ManualSensorImportView(model: model)
        }
        .task {
            model.runLaunchAutomationIfRequested()
        }
        .onChange(of: scenePhase) { _, phase in
            model.recordScenePhase(phase)
        }
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(model.scanning ? Color.orange : Color.green)
                .frame(width: 10, height: 10)
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var receiverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Receiver").font(.headline)
            monoLabel("uniqueID", model.uniqueID)
            monoLabel("receiverID", model.receiverIDHex)
            monoLabel("source", model.receiverIDSource)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.readPatchInfo()
            } label: {
                Label("Read sensor", systemImage: "wave.3.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.scanning)

            Button {
                model.runFirstPairCandidate()
            } label: {
                Label("Run pairing candidate", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(model.scanning)

            Button {
                showingManualImport = true
            } label: {
                Label("Introdu datele manual", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var decodedDataSection: some View {
        if model.latestGlucose != nil || model.latestPatchStatus != nil || !model.recentDecodedPackets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text("Decoded data").font(.headline)
                    Spacer()
                    Button {
                        model.clearDecodedData()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Clear decoded data")
                }

                if let glucose = model.latestGlucose {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(glucose.currentDisplay)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                        monoLabel("lifeCount", "\(glucose.lifeCount)")
                        monoLabel("rate", glucose.rateDisplay)
                        monoLabel("trend", "\(glucose.trend)")
                        monoLabel("history", glucose.historicalDisplay)
                        monoLabel("tempRaw", "\(glucose.temperatureRaw)")
                        monoLabel("statusBits", "\(glucose.statusBits)")
                        monoLabel("seq", glucose.sequenceDisplay)
                        Text(glucose.receivedDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let patch = model.latestPatchStatus {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Patch status").font(.subheadline).bold()
                        monoLabel("state", "\(patch.patchState) \(patch.patchStateKind)")
                        monoLabel("lifeCount", "\(patch.currentLifeCount)")
                        monoLabel("phase", patch.lifecyclePhase)
                        monoLabel("wearLeft", patch.remainingWearDisplay)
                        monoLabel("events", "\(patch.totalEvents)")
                        monoLabel("stackDisc", "\(patch.stackDisconnectReason)")
                        monoLabel("appDisc", "\(patch.appDisconnectReason)")
                        monoLabel("seq", patch.sequenceDisplay)
                    }
                }

                if model.historicalBackfill.samples.count > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Backfill").font(.subheadline).bold()
                        monoLabel("samples", "\(model.historicalBackfill.samples.count)")
                        monoLabel("range", model.historicalBackfillRangeDisplay)
                        monoLabel("gaps", model.historicalBackfillGapDisplay)
                    }
                }

                if !model.glucoseReadings.isEmpty {
                    Text("Recent glucose").font(.subheadline).bold()
                    ForEach(model.glucoseReadings.prefix(6)) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(reading.currentDisplay)  lc \(reading.lifeCount)  rate \(reading.rateDisplay)")
                                .font(.system(.caption, design: .monospaced))
                            Text(reading.receivedDisplay)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.recentDecodedPackets.isEmpty {
                    Text("Recent packets").font(.subheadline).bold()
                    ForEach(model.recentDecodedPackets.prefix(8)) { packet in
                        Text(packet.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Pairing connection").font(.headline)
            monoLabel("status", model.bleHandoffStatus)
            monoLabel("reconnect", model.reconnectStatus)
            monoLabel("active", model.activeConnectionDisplay)
            HStack {
                Button {
                    model.disconnectActiveSession()
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasActiveConnection)

                Button {
                    model.registerWakeEvents()
                } label: {
                    Label("Register wake", systemImage: "alarm")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Apple Watch").font(.headline)
            Toggle("Conexiune directă pe Apple Watch", isOn: $model.watchDirectConnectionEnabled)
            monoLabel(
                "owner",
                model.watchDirectConnectionEnabled ? "watch" : "iphone"
            )
        }
    }

    @ViewBuilder
    private var persistenceSection: some View {
        if model.activatedSensorState != nil || model.persistedSensorState != nil ||
            model.savedSensorStateURL != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Saved sensor state").font(.headline)
                if let url = model.savedSensorStateURL {
                    monoLabel("file", url.lastPathComponent)
                }
                if let state = model.persistedSensorState ?? model.activatedSensorState {
                    monoLabel("serial", state.serialNumber ?? "")
                    monoLabel("ble", state.bleAddress ?? "")
                    monoLabel("blePIN", hex(state.blePIN))
                    monoLabel("receiverID", state.receiverID?.displayString ?? "nil")
                    monoLabel("lastGlucoseLC", state.lastGlucoseLifeCount.map(String.init) ?? "nil")
                    monoLabel("lastGlucose", state.lastGlucoseMgDL.map { "\($0) mg/dL" } ?? "nil")
                    if let source = state.source {
                        monoLabel("source", source)
                    }
                }
                HStack {
                    Button {
                        model.reloadPersistedState()
                    } label: {
                        Label("Reload", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.connectPersistedState()
                    } label: {
                        Label("Pair saved", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.bleHandoffRunning || (model.persistedSensorState == nil && model.activatedSensorState == nil))
                }
            }
        }
    }

    @ViewBuilder
    private var patchSection: some View {
        if let patch = model.patchInfo {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Patch").font(.headline)
                monoLabel("serial", patch.serialNumber)
                monoLabel("state", String(format: "0x%02x", patch.stateByte))
                monoLabel("fw", patch.firmwareVersion)
                monoLabel("next", patch.recommendedCommandCode == .activate ? "A0" : "A8")
                Text(hex(patch.raw))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var activationSection: some View {
        if let activation = model.activationResponse {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Activation").font(.headline).foregroundStyle(.green)
                monoLabel("ble", activation.bleAddressDisplay)
                monoLabel("blePIN", hex(activation.blePIN))
                monoLabel("raw", hex(activation.raw))
                if let state = model.activatedSensorState {
                    monoLabel("state", stateJSON(state))
                }
            }
        }
    }

    @ViewBuilder
    private var bleHandoffSection: some View {
        if model.activatedSensorState != nil || model.bleHandoffRunning ||
            model.savedSensorStateURL != nil || model.bleBootstrapSummary != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Pairing transcript").font(.headline)
                monoLabel("status", model.bleHandoffStatus)
                if let url = model.savedSensorStateURL {
                    monoLabel("stateFile", url.lastPathComponent)
                }
                if let summary = model.bleBootstrapSummary {
                    Text(summary)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button {
                    model.retryBLEHandoff()
                } label: {
                    Label("Retry pairing", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.bleHandoffRunning || model.activatedSensorState == nil)
            }
        }
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        if !model.lifecycleEvents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Text("Lifecycle").font(.headline)
                    Spacer()
                    Button {
                        model.copyLifecycleEventsToPasteboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy lifecycle events")
                }
                monoLabel("scene", model.latestScenePhase)
                ForEach(Array(model.lifecycleEvents.suffix(12))) { event in
                    Text(event.summary)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func monoLabel(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func stateJSON(_ state: Libre3SensorState) -> String {
        var fields = [
            "\"serialNumber\":\"\(state.serialNumber ?? "")\"",
            "\"bleAddress\":\"\(state.bleAddress ?? "")\"",
            "\"blePIN\":\"\(hex(state.blePIN))\"",
        ]
        if let receiverID = state.receiverID {
            fields.append("\"receiverID\":\"\(receiverID.littleEndianHex)\"")
        }
        if let phase5RawKey = state.phase5RawKey {
            fields.append("\"phase5RawKey\":\"\(hex(phase5RawKey))\"")
        }
        if let lastGlucoseLifeCount = state.lastGlucoseLifeCount {
            fields.append("\"lastGlucoseLifeCount\":\(lastGlucoseLifeCount)")
        }
        if let lastGlucoseMgDL = state.lastGlucoseMgDL {
            fields.append("\"lastGlucoseMgDL\":\(lastGlucoseMgDL)")
        }
        if let source = state.source {
            fields.append("\"source\":\"\(source)\"")
        }
        return "{\(fields.joined(separator: ","))}"
    }
}

struct ManualSensorImportView: View {
    @ObservedObject var model: NFCActivationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var rawActivationResponse = ""
    @State private var serialNumber: String
    @State private var bleAddress: String
    @State private var blePIN: String
    @State private var phase5RawKey: String
    @State private var receiverIDLittleEndian: String
    @State private var externalCommandTimeSeconds: UInt32
    @State private var connectAfterSaving = true
    @State private var feedback: String?
    @State private var feedbackIsError = false

    init(model: NFCActivationViewModel) {
        self.model = model
        let state = model.persistedSensorState ?? model.activatedSensorState
        _serialNumber = State(initialValue: state?.serialNumber ?? "")
        _bleAddress = State(initialValue: state?.bleAddress ?? "")
        _blePIN = State(initialValue: state.map { Self.hex($0.blePIN) } ?? "")
        _phase5RawKey = State(initialValue: state?.phase5RawKey.map { Self.hex($0) } ?? "")
        _receiverIDLittleEndian = State(
            initialValue: state?.receiverID?.littleEndianHex ??
                Libre3ReceiverID(model.receiverID).littleEndianHex
        )
        _externalCommandTimeSeconds = State(initialValue: Self.defaultExternalCommandTimeSeconds())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Răspuns NFC brut") {
                    Text("Poți lipi răspunsul primit după A0/A8. Aplicația extrage automat adresa BLE și PIN-ul.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $rawActivationResponse)
                        .frame(minHeight: 76)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        extractActivationResponse()
                    } label: {
                        Label("Extrage adresa și PIN-ul", systemImage: "wand.and.stars")
                    }
                    .disabled(rawActivationResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Date senzor") {
                    TextField("Serie (opțional)", text: $serialNumber)
                    TextField("Adresă BLE, ex. AA:BB:CC:DD:EE:FF", text: $bleAddress)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("BLE PIN, 4 bytes hex", text: $blePIN)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("Adresa BLE și PIN-ul sunt obligatorii. Datele trebuie să provină din răspunsul A0/A8, nu doar din patch info.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Cheie Phase 5 (recuperare)") {
                    TextField("Phase 5 raw key, 16 bytes hex (opțional)", text: $phase5RawKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("Lipește cheia reală (32 caractere hex) dintr-un log al unei sesiuni care arăta glicemii — linia 'phase5RawKey'/'cachedPhase5RawKey'. Reconnect-ul o reia direct, fără re-pairing. Lasă gol ca să nu o modifici.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Receiver ID") {
                    TextField("Receiver ID little-endian, 4 bytes hex", text: $receiverIDLittleEndian)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("Aplicația NFC externă trebuie să trimită A0 sau A8 folosind exact acest receiver ID. Un răspuns generat cu receiver ID-ul altei aplicații nu poate prelua corect sesiunea LibreCR.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Comandă pentru aplicația NFC externă") {
                    Text("Pentru un senzor deja activ folosește A0 cu Receiver ID-ul de mai sus, ca să citești PIN-ul curent. Pentru un senzor nou în starea 0x01 folosește A8. A8 pe un senzor activ poate schimba PIN-ul.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    externalCommandRow("manufacturer", value: "7a")
                    externalCommandRow("A1 patch info", value: "02a17a")
                    TextField(
                        "Timestamp Unix (secunde)",
                        value: $externalCommandTimeSeconds,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                    externalCommandRow(
                        "timestamp LE",
                        value: Self.littleEndianHex(externalCommandTimeSeconds)
                    )
                    externalCommandRow("A0 params", value: externalCommandParameters())
                    externalCommandRow("A0 full", value: externalCommand(.activate))
                    externalCommandRow("A8 params", value: externalCommandParameters())
                    externalCommandRow("A8 full", value: externalCommand(.switchReceiver))
                    Button {
                        externalCommandTimeSeconds = Self.defaultExternalCommandTimeSeconds()
                    } label: {
                        Label("Regenerează timestamp", systemImage: "arrow.clockwise")
                    }
                }

                Section {
                    Toggle("Conectează prin BLE după salvare", isOn: $connectAfterSaving)
                    Button {
                        save()
                    } label: {
                        Label("Salvează datele senzorului", systemImage: "externaldrive.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let feedback {
                    Section {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(feedbackIsError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Import manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Închide") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func extractActivationResponse() {
        do {
            guard let raw = Self.parseHex(rawActivationResponse) else {
                throw ManualSensorImportError.invalidActivationResponseHex
            }
            let response = try Libre3NFCActivationResponse(raw: raw)
            bleAddress = response.bleAddressDisplay
            blePIN = Self.hex(response.blePIN)
            feedback = "Adresa BLE și PIN-ul au fost extrase."
            feedbackIsError = false
        } catch {
            feedback = "Răspuns NFC invalid: \(error.localizedDescription)"
            feedbackIsError = true
        }
    }

    private func save() {
        do {
            try model.importManualSensorState(
                serialNumber: serialNumber,
                bleAddress: bleAddress,
                blePINHex: blePIN,
                receiverIDLittleEndianHex: receiverIDLittleEndian,
                phase5RawKeyHex: phase5RawKey,
                connectAfterSaving: connectAfterSaving
            )
            dismiss()
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    @ViewBuilder
    private func externalCommandRow(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func externalCommandParameters() -> String {
        guard let receiverID = Libre3ReceiverID.parseLittleEndianHex(receiverIDLittleEndian) else {
            return "receiver ID invalid"
        }
        return Self.hex(
            NFCActivationCommand.customRequestParameters(
                timeSeconds: externalCommandTimeSeconds,
                receiverID: receiverID
            )
        )
    }

    private func externalCommand(_ code: NFCActivationCommandCode) -> String {
        guard let receiverID = Libre3ReceiverID.parseLittleEndianHex(receiverIDLittleEndian) else {
            return "receiver ID invalid"
        }
        return Self.hex(
            NFCActivationCommand.command(
                code: code,
                timeSeconds: externalCommandTimeSeconds,
                receiverID: receiverID
            )
        )
    }

    private static func defaultExternalCommandTimeSeconds() -> UInt32 {
        let now = UInt64(Date().timeIntervalSince1970.rounded(.down))
        return UInt32(max(0, now - 1))
    }

    private static func littleEndianHex(_ value: UInt32) -> String {
        hex(
            Data([
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff),
            ])
        )
    }

    private static func parseHex(_ raw: String) -> Data? {
        let compact = raw
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard !compact.isEmpty,
              compact.count.isMultiple(of: 2),
              compact.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var data = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ManualSensorImportError: LocalizedError {
    case invalidActivationResponseHex
    case invalidHex(field: String, expectedByteCount: Int)
    case invalidReceiverID

    var errorDescription: String? {
        switch self {
        case .invalidActivationResponseHex:
            return "Introdu un răspuns NFC hex valid."
        case .invalidHex(let field, let expectedByteCount):
            return "\(field) trebuie să conțină exact \(expectedByteCount) bytes hex."
        case .invalidReceiverID:
            return "Receiver ID trebuie să conțină exact 4 bytes hex în ordine little-endian."
        }
    }
}

struct GlucoseDisplay: Identifiable, Equatable {
    let id = UUID()
    let receivedAt: Date
    let sequenceNumber: UInt16
    let lifeCount: UInt16
    let currentGlucoseMgDL: UInt16?
    let rateOfChangeMgDLPerMinute: Float?
    let trend: UInt8
    let statusBits: UInt8
    let historicalLifeCount: UInt16
    let historicalGlucoseMgDL: UInt16?
    let temperatureRaw: UInt16
    let fastDataWordsLE: [UInt16]
    let plaintextHex: String

    var currentDisplay: String {
        currentGlucoseMgDL.map { "\($0) mg/dL" } ?? "invalid"
    }

    var rateDisplay: String {
        rateOfChangeMgDLPerMinute.map { String(format: "%.2f mg/dL/min", $0) } ?? "nil"
    }

    var historicalDisplay: String {
        let value = historicalGlucoseMgDL.map(String.init) ?? "invalid"
        return "\(value) @ \(historicalLifeCount)"
    }

    var sequenceDisplay: String {
        String(format: "0x%04x", sequenceNumber)
    }

    var receivedDisplay: String {
        receivedAt.formatted(date: .omitted, time: .standard)
    }
}

struct PatchStatusDisplay: Identifiable, Equatable {
    let id = UUID()
    let receivedAt: Date
    let sequenceNumber: UInt16
    let patchState: Int8
    let patchStateKind: Libre3PatchState
    let currentLifeCount: Int16
    let lifecyclePhase: String
    let remainingWarmupMinutes: Int
    let remainingWearMinutes: Int?
    let totalEvents: Int
    let stackDisconnectReason: Int8
    let appDisconnectReason: Int8

    var sequenceDisplay: String {
        String(format: "0x%04x", sequenceNumber)
    }

    var remainingWearDisplay: String {
        remainingWearMinutes.map(String.init) ?? "unknown"
    }
}

struct DecodedPacketDisplay: Identifiable, Equatable {
    let id = UUID()
    let receivedAt: Date
    let summary: String
}

struct LifecycleEventDisplay: Identifiable, Equatable {
    let id = UUID()
    let occurredAt: Date
    let message: String

    var summary: String {
        "[\(occurredAt.formatted(date: .omitted, time: .standard))] \(message)"
    }
}

@MainActor
final class NFCActivationViewModel: ObservableObject {
    private static let buildMarker = "2026-06-02-fast-postauth-cccd"
    private static let watchDirectConnectionEnabledDefaultsKey = "LibreCRWatchDirectConnectionEnabled"

    @Published var statusText = "Ready"
    @Published var scanning = false
    @Published var patchInfo: Libre3NFCPatchInfo?
    @Published var activationResponse: Libre3NFCActivationResponse?
    @Published var activatedSensorState: Libre3SensorState?
    @Published var savedSensorStateURL: URL?
    @Published var persistedSensorState: Libre3SensorState?
    @Published var bleHandoffStatus = "Idle"
    @Published var bleHandoffRunning = false
    @Published var bleBootstrapSummary: String?
    @Published var lastError: String?
    @Published var latestGlucose: GlucoseDisplay?
    @Published var glucoseReadings: [GlucoseDisplay] = []
    @Published var latestPatchStatus: PatchStatusDisplay?
    @Published var historicalBackfill = HistoricalBackfill()
    @Published var recentDecodedPackets: [DecodedPacketDisplay] = []
    @Published var lifecycleEvents: [LifecycleEventDisplay] = []
    @Published var latestScenePhase = "unknown"
    @Published var hasActiveConnection = false
    @Published var activeConnectionDisplay = "none"
    @Published var reconnectStatus = "idle"
    @Published var watchDirectConnectionEnabled = UserDefaults.standard.bool(
        forKey: "LibreCRWatchDirectConnectionEnabled"
    ) {
        didSet {
            guard oldValue != watchDirectConnectionEnabled else {
                return
            }
            UserDefaults.standard.set(
                watchDirectConnectionEnabled,
                forKey: Self.watchDirectConnectionEnabledDefaultsKey
            )
            WatchSensorStateSyncCoordinator.shared.publishDirectConnectionEnabled(
                watchDirectConnectionEnabled,
                guaranteeDelivery: true
            )
            applyWatchDirectConnectionPreference(reason: watchDirectConnectionChangeReason)
        }
    }

    let readingStore = GlucoseReadingStore()
    let uniqueID: String
    let receiverID: UInt32
    let receiverIDSource: String
    private let reader = Libre3NFCActivationReader()
    private let scanner = SensorScanner(
        configuration: SensorScannerConfiguration(
            restorationIdentifier: "org.librecrkit.librecr.pairing-central",
            notifyOnConnection: true,
            notifyOnDisconnection: true,
            notifyOnNotification: true
        )
    )
    private let bleScanTimeout: TimeInterval = 90
    private let knownPeripheralConnectTimeout: TimeInterval = 18
    private let discoveredPeripheralConnectTimeout: TimeInterval = 45
    private let postAuthInitialListenDuration: TimeInterval = 160
    private var activeSession: SensorSession?
    private var activePeripheralID: UUID?
    private var activePeripheralName: String?
    private var targetPeripheralID: UUID?
    private var desiredSensorState: Libre3SensorState?
    /// Consecutive failures of the fast cached-reconnect path, for logging only.
    /// The cached key is intentionally never auto-retired: the candidate
    /// first-pair fallback is a dead end on an already-paired sensor (its ~30s
    /// derivation trips the sensor supervision timeout), so dropping the key only
    /// makes things worse. A wrong key is corrected via manual import recovery.
    private var cachedReconnectFailureStreak = 0
    private var activeSessionMaterial: Phase6SessionMaterial?
    private var postAuthListenTask: Task<Void, Never>?
    private var postAuthListenerGeneration = 0
    private var reconnectTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var pendingReconnectReason: String?
    private var pendingReconnectPeripheral: CBPeripheral?
    private var autoReconnectEnabled = false
    private var watchDirectConnectionChangeReason = "user-toggle"
    private var dataPlaneSessionEstablished = false
    private var reconnectAttempt = 0
    private var cachedFirstPairNativeEphemeral: (
        sensorKey: String,
        material: FirstPairNativeEphemeralMaterial
    )?
    private let launchSendCandidatePhase5 = ProcessInfo.processInfo.arguments.contains("--send-candidate-firstpair-phase5") ||
        ProcessInfo.processInfo.arguments.contains("--auto-firstpair-candidate")
    private let autoNFCRead = ProcessInfo.processInfo.arguments.contains("--auto-nfc-read")
    private let autoNFCActivate = ProcessInfo.processInfo.arguments.contains("--auto-nfc-activate")
    private let autoNFCSwitchReceiver = ProcessInfo.processInfo.arguments.contains("--auto-nfc-switch-receiver")
    private let autoNFCActivateOrSwitch = ProcessInfo.processInfo.arguments.contains("--auto-nfc-activate-or-switch")
    private let autoNFCForceA0 = ProcessInfo.processInfo.arguments.contains("--auto-nfc-force-a0")
    private let autoNFCForceA8 = ProcessInfo.processInfo.arguments.contains("--auto-nfc-force-a8")
    private let autoFirstPairCandidate = ProcessInfo.processInfo.arguments.contains("--auto-firstpair-candidate")
    private let allowLateA8FirstPairCandidate = ProcessInfo.processInfo.arguments.contains("--allow-late-a8-firstpair-candidate")
    private let debugClinicalAfterHistory = ProcessInfo.processInfo.arguments.contains("--post-auth-clinical")
    private let skipPostAuthHistory = ProcessInfo.processInfo.arguments.contains("--skip-post-auth-history")
    private let autoConnectSavedState = !ProcessInfo.processInfo.arguments.contains("--no-auto-connect-saved-state")
    private let enableFastCachedReconnect = !ProcessInfo.processInfo.arguments.contains("--no-fast-cached-reconnect")
    private let launchUseCapturedUserCert = ProcessInfo.processInfo.arguments.contains("--phone-cert-162b") ||
        ProcessInfo.processInfo.arguments.contains("--user-fresh-pair-cert")
    private var manualSendCandidatePhase5 = false
    private var manualUseCapturedUserCert = false
    private var launchAutomationStarted = false

    private var sendCandidatePhase5: Bool {
        launchSendCandidatePhase5 || manualSendCandidatePhase5
    }

    private var useCapturedUserCert: Bool {
        launchUseCapturedUserCert || manualUseCapturedUserCert || autoFirstPairCandidate
    }

    private var phoneCertLabel: String {
        useCapturedUserCert ? "phone_cert_162b" : "phone_cert_firstpair"
    }

    var receiverIDHex: String {
        Libre3ReceiverID(receiverID).displayString
    }

    init() {
        let key = "LibreCRAccountlessUniqueID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            uniqueID = existing
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: key)
            uniqueID = created
        }
        if let override = Self.receiverIDOverride(from: ProcessInfo.processInfo.arguments) {
            receiverID = override.id
            receiverIDSource = override.source
        } else {
            receiverID = NFCActivationCommand.accountlessReceiverID(from: uniqueID)
            receiverIDSource = "accountless uniqueID"
        }
        appendHandoffLog(
            "App build marker=\(Self.buildMarker) " +
            "args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))"
        )
        WatchSensorStateSyncCoordinator.shared.publishDirectConnectionEnabled(
            watchDirectConnectionEnabled,
            guaranteeDelivery: false
        )
        loadPersistedSensorState()
        observeScannerLifecycle()
        // Route the kit's BLE instrumentation (state, scan start/stop, every
        // discovery, connect/disconnect, discover+subscribe timing) into the
        // same persisted handoff log the UI already shows. Set last, once all
        // stored properties are initialized, so the closure may capture self.
        // Hops to the main actor because BLETiming fires from the CB queue.
        BLETiming.setLogger { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendHandoffLog("BLE: \(message)")
            }
        }
    }

    func readPatchInfo() {
        manualSendCandidatePhase5 = false
        manualUseCapturedUserCert = false
        run(.readPatchInfo)
    }

    func importManualSensorState(
        serialNumber: String,
        bleAddress: String,
        blePINHex: String,
        receiverIDLittleEndianHex: String,
        phase5RawKeyHex: String = "",
        connectAfterSaving: Bool
    ) throws {
        let normalizedBLEAddress = try Self.manualBLEAddress(from: bleAddress)
        let blePIN = try Self.manualHexData(
            blePINHex,
            expectedByteCount: 4,
            field: "BLE PIN"
        )
        let receiverHex = receiverIDLittleEndianHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedReceiverID: Libre3ReceiverID
        if receiverHex.isEmpty {
            importedReceiverID = Libre3ReceiverID(receiverID)
        } else {
            guard let value = Libre3ReceiverID.parseLittleEndianHex(receiverHex) else {
                throw ManualSensorImportError.invalidReceiverID
            }
            importedReceiverID = Libre3ReceiverID(value)
        }
        // Optional Phase 5 raw key recovery: a 16-byte (32 hex char) key pulled
        // from a prior working session's logs. Replayed by the cached reconnect
        // path so a sensor that has already accepted this key authorizes again.
        let trimmedPhase5 = phase5RawKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let phase5RawKey: Data?
        if trimmedPhase5.isEmpty {
            phase5RawKey = nil
        } else {
            phase5RawKey = try Self.manualHexData(
                trimmedPhase5,
                expectedByteCount: 16,
                field: "Phase 5 raw key"
            )
        }
        let trimmedSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = try Libre3SensorState(
            serialNumber: trimmedSerial.isEmpty ? nil : trimmedSerial,
            blePIN: blePIN,
            bleAddress: normalizedBLEAddress,
            receiverID: importedReceiverID,
            source: "manual NFC import",
            phase5RawKey: phase5RawKey
        )
        savedSensorStateURL = try saveActivatedState(state)
        activatedSensorState = state
        // A freshly supplied key gets a clean slate against the retire-after-N
        // guard so a stale streak from the previous key cannot drop it.
        cachedReconnectFailureStreak = 0
        lastError = nil
        statusText = "Saved manual sensor data"
        appendHandoffLog(
            "Manual sensor import serial=\(state.serialNumber ?? "") " +
            "ble=\(normalizedBLEAddress) receiverID=\(importedReceiverID.littleEndianHex) " +
            "phase5RawKey=\(phase5RawKey != nil ? "set" : "none")"
        )
        if connectAfterSaving {
            connectPersistedState()
        }
    }

    func activateFreshSensor() {
        manualSendCandidatePhase5 = false
        manualUseCapturedUserCert = false
        run(.activateFreshSensor(receiverID: receiverID))
    }

    func runFirstPairCandidate() {
        manualSendCandidatePhase5 = true
        manualUseCapturedUserCert = true
        appendHandoffLog("Manual pairing candidate: activate-or-switch with candidate Phase 5 and phone_cert_162b")
        activateOrSwitchReceiver()
    }

    func switchReceiver() {
        run(.switchReceiver(receiverID: receiverID))
    }

    func activateOrSwitchReceiver() {
        run(.activateOrSwitchReceiver(receiverID: receiverID))
    }

    func forceActivationCommand(_ commandCode: NFCActivationCommandCode) {
        run(.forceActivationCommand(commandCode: commandCode, receiverID: receiverID))
    }

    func runLaunchAutomationIfRequested() {
        guard !launchAutomationStarted, !scanning else { return }
        launchAutomationStarted = true
        if autoFirstPairCandidate {
            appendHandoffLog("Launch automation: auto first-pair candidate")
            activateOrSwitchReceiver()
        } else if autoNFCForceA0 {
            appendHandoffLog("Launch automation: auto NFC force A0")
            forceActivationCommand(.activate)
        } else if autoNFCForceA8 {
            appendHandoffLog("Launch automation: auto NFC force A8")
            forceActivationCommand(.switchReceiver)
        } else if autoNFCActivateOrSwitch {
            appendHandoffLog("Launch automation: auto NFC activate-or-switch")
            activateOrSwitchReceiver()
        } else if autoNFCSwitchReceiver {
            appendHandoffLog("Launch automation: auto NFC switch receiver")
            switchReceiver()
        } else if autoNFCActivate {
            appendHandoffLog("Launch automation: auto NFC activate")
            activateFreshSensor()
        } else if autoNFCRead {
            appendHandoffLog("Launch automation: auto NFC read")
            readPatchInfo()
        } else if sendCandidatePhase5 {
            appendHandoffLog("Launch automation: NFC tab selected; waiting for manual activate")
        } else if autoConnectSavedState,
                  !watchDirectConnectionEnabled,
                  persistedSensorState != nil || activatedSensorState != nil {
            appendHandoffLog("Launch automation: saved-state reconnect")
            connectPersistedState()
        }
    }

    private func run(_ mode: Libre3NFCScanMode) {
        scanning = true
        lastError = nil
        activationResponse = nil
        activatedSensorState = nil
        bleBootstrapSummary = nil
        statusText = "Scanning…"
        appendHandoffLog(
            "NFC scan started sendCandidatePhase5=\(sendCandidatePhase5) " +
            "phoneCert=\(phoneCertLabel) " +
            "receiverID=\(receiverIDHex) receiverSource=\(receiverIDSource)"
        )

        Task {
            do {
                let result = try await reader.scan(mode: mode)
                patchInfo = result.patchInfo
                activationResponse = result.activationResponse
                appendHandoffLog(
                    "NFC patch serial=\(result.patchInfo.serialNumber) " +
                    "state=0x\(String(format: "%02x", result.patchInfo.stateByte)) " +
                    "next=\(result.patchInfo.recommendedCommandCode == .activate ? "A0" : "A8") " +
                    "raw=\(Self.hex(result.patchInfo.raw)) " +
                    "inputRaw=\(Self.hex(result.patchInfo.inputRaw))"
                )
                if let activation = result.activationResponse {
                    let source = result.patchInfo.isStorageState
                        ? "NFC fresh activation response"
                        : "NFC active takeover response"
                    let state = try activation.sensorState(
                        serialNumber: result.patchInfo.serialNumber,
                        receiverID: Libre3ReceiverID(receiverID),
                        patchInfo: result.patchInfo,
                        source: source
                    )
                    activatedSensorState = state
                    savedSensorStateURL = try saveActivatedState(state)
                    statusText = result.patchInfo.isStorageState
                        ? "Activated \(activation.bleAddressDisplay)"
                        : "Takeover data \(activation.bleAddressDisplay)"
                    appendHandoffLog(
                        "NFC response command=\(result.commandCode == .switchReceiver ? "A8" : "A0") " +
                        "ble=\(activation.bleAddressDisplay) " +
                        "blePIN=\(Self.hex(activation.blePIN)) " +
                        "activationTimeRaw=\(Self.hex(activation.activationTimeRaw)) " +
                        "activationTime=\(activation.activationTimeSeconds) " +
                        "stateFile=\(savedSensorStateURL?.lastPathComponent ?? "")"
                    )
                    if shouldSkipFirstPairCandidateBLE(
                        patchInfo: result.patchInfo,
                        commandCode: result.commandCode
                    ) {
                        bleHandoffStatus = "Skipped late A8 first-pair candidate"
                        appendHandoffLog(
                            "BLE handoff skipped reason=late-a8-firstpair-candidate " +
                            "state=0x\(String(format: "%02x", result.patchInfo.stateByte)) " +
                            "override=--allow-late-a8-firstpair-candidate"
                        )
                    } else {
                        startBLEHandoff(with: state, reason: "nfc-scan")
                    }
                } else {
                    statusText = "Read \(result.patchInfo.serialNumber)"
                }
            } catch {
                lastError = String(describing: error)
                statusText = "NFC failed"
                appendHandoffLog("NFC failed error=\(String(describing: error))")
            }
            scanning = false
        }
    }

    func retryBLEHandoff() {
        guard let state = activatedSensorState else { return }
        if let patchInfo,
           shouldSkipFirstPairCandidateBLE(
               patchInfo: patchInfo,
               commandCode: patchInfo.recommendedCommandCode
           ) {
            bleHandoffStatus = "Skipped late A8 first-pair candidate"
            appendHandoffLog(
                "BLE handoff retry skipped reason=late-a8-firstpair-candidate " +
                "state=0x\(String(format: "%02x", patchInfo.stateByte)) " +
                "override=--allow-late-a8-firstpair-candidate"
            )
            return
        }
        startBLEHandoff(with: state, reason: "retry")
    }

    private func shouldSkipFirstPairCandidateBLE(
        patchInfo: Libre3NFCPatchInfo,
        commandCode: NFCActivationCommandCode?
    ) -> Bool {
        sendCandidatePhase5 &&
            commandCode == .switchReceiver &&
            patchInfo.stateByte >= 0x04 &&
            !manualSendCandidatePhase5 &&
            !allowLateA8FirstPairCandidate
    }

    private func saveActivatedState(_ state: Libre3SensorState) throws -> URL {
        var state = state
        if state.phase5RawKey == nil,
           let existing = persistedSensorState ?? desiredSensorState,
           let existingPhase5RawKey = existing.phase5RawKey,
           Self.isSameSensor(state, existing) {
            state = try state.updatingPhase5RawKey(existingPhase5RawKey)
        }
        let url = sensorStateFileURL()
        try Libre3SensorStateLoader.write(state, to: url)
        persistedSensorState = state
        savedSensorStateURL = url
        WatchSensorStateSyncCoordinator.shared.publish(state, guaranteeDelivery: true)
        appendLifecycleEvent(
            "persisted sensor serial=\(state.serialNumber ?? "") " +
            "ble=\(state.bleAddress ?? "") receiverID=\(state.receiverID?.littleEndianHex ?? "nil")"
        )
        return url
    }

    private func persistLastGlucose(lifeCount: UInt16, mgDL: UInt16?) {
        guard let state = persistedSensorState ?? activatedSensorState ?? desiredSensorState else {
            return
        }
        guard state.lastGlucoseLifeCount != lifeCount || state.lastGlucoseMgDL != mgDL else {
            return
        }
        do {
            let updated = try state.updatingLastGlucose(lifeCount: lifeCount, mgDL: mgDL)
            let url = sensorStateFileURL()
            try Libre3SensorStateLoader.write(updated, to: url)
            persistedSensorState = updated
            savedSensorStateURL = url
            WatchSensorStateSyncCoordinator.shared.publish(updated, guaranteeDelivery: false)
            if activatedSensorState?.serialNumber == state.serialNumber {
                activatedSensorState = updated
            }
            if desiredSensorState?.serialNumber == state.serialNumber {
                desiredSensorState = updated
            }
            appendLifecycleEvent(
                "persisted last glucose lc=\(lifeCount) value=\(mgDL.map(String.init) ?? "nil")"
            )
        } catch {
            appendLifecycleEvent("last glucose persist failed: \(String(describing: error))")
        }
    }

    private func persistPhase5RawKey(_ rawKey: Data, for state: Libre3SensorState) {
        guard state.phase5RawKey != rawKey else {
            return
        }
        do {
            let updated = try state.updatingPhase5RawKey(rawKey)
            let url = sensorStateFileURL()
            try Libre3SensorStateLoader.write(updated, to: url)
            persistedSensorState = updated
            savedSensorStateURL = url
            WatchSensorStateSyncCoordinator.shared.publish(updated, guaranteeDelivery: true)
            if activatedSensorState?.serialNumber == state.serialNumber {
                activatedSensorState = updated
            }
            if desiredSensorState?.serialNumber == state.serialNumber {
                desiredSensorState = updated
            }
            appendLifecycleEvent("persisted Phase 5 raw key for watch reconnect")
        } catch {
            appendLifecycleEvent("Phase 5 raw key persist failed: \(String(describing: error))")
        }
    }

    func reloadPersistedState() {
        loadPersistedSensorState(reportMissing: true)
    }

    func connectPersistedState() {
        guard let state = persistedSensorState ?? activatedSensorState else {
            lastError = "No saved sensor state"
            appendLifecycleEvent("saved-state pairing requested without saved state")
            return
        }
        // Automatic fallback: with no saved Phase 5 key the fast saved-state
        // path can't run, and a bare-BLE candidate first-pair is a dead end on
        // an already-paired sensor (the ~30s Phase 5 derivation trips the link
        // supervision timeout — see runFirstPairPreamble). The only reliable
        // way to obtain the key is a candidate first-pair inside a fresh NFC
        // activate/switch window, so route there once. It persists (and syncs
        // to the Watch) the derived key, after which reconnects use the fast
        // cached path. Requires the sensor near the phone for the NFC scan.
        guard state.phase5RawKey != nil else {
            appendHandoffLog(
                "Saved-state pairing requested without Phase 5 key — routing to NFC " +
                "candidate first-pair to obtain and persist one " +
                "serial=\(state.serialNumber ?? "") ble=\(state.bleAddress ?? "")"
            )
            bleHandoffStatus = "Lipsă cheie Phase 5 — apropie senzorul pentru pairing"
            runFirstPairCandidate()
            return
        }
        if watchDirectConnectionEnabled {
            watchDirectConnectionChangeReason = "pair-saved"
            watchDirectConnectionEnabled = false
            watchDirectConnectionChangeReason = "user-toggle"
        }
        manualSendCandidatePhase5 = false
        manualUseCapturedUserCert = true
        appendHandoffLog(
            "Saved-state pairing requested serial=\(state.serialNumber ?? "") " +
            "ble=\(state.bleAddress ?? "") receiverID=\(state.receiverID?.littleEndianHex ?? "nil") " +
            "phase5RawKey=\(state.phase5RawKey == nil ? "missing" : "set")"
        )
        startBLEHandoff(with: state, reason: "saved-state")
    }

    func disconnectActiveSession() {
        guard let session = activeSession else {
            appendLifecycleEvent("disconnect requested with no active session")
            return
        }
        autoReconnectEnabled = false
        pendingReconnectReason = nil
        pendingReconnectPeripheral = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        postAuthListenTask?.cancel()
        postAuthListenTask = nil
        postAuthListenerGeneration += 1
        reconnectStatus = "disabled by manual disconnect"
        appendLifecycleEvent("disconnect requested target=\(activeConnectionDisplay)")
        registerWakeEventsForCurrentSession(reason: "before-disconnect")
        scanner.disconnect(session)
        clearActiveSession(resetTarget: false)
        bleHandoffStatus = "Disconnect requested"
    }

    private func applyWatchDirectConnectionPreference(reason: String) {
        appendLifecycleEvent(
            "watch direct \(watchDirectConnectionEnabled ? "enabled" : "disabled") reason=\(reason)"
        )
        if let state = persistedSensorState ?? activatedSensorState ?? desiredSensorState {
            WatchSensorStateSyncCoordinator.shared.publish(state, guaranteeDelivery: true)
        }

        if watchDirectConnectionEnabled {
            pausePhoneConnectionForWatch(reason: reason)
            return
        }

        guard let state = persistedSensorState ?? activatedSensorState ?? desiredSensorState else {
            reconnectStatus = "watch direct disabled"
            return
        }
        desiredSensorState = state
        autoReconnectEnabled = autoConnectSavedState
        reconnectStatus = autoReconnectEnabled
            ? "watch direct disabled; iphone reconnect"
            : "watch direct disabled"
        if autoReconnectEnabled,
           reason != "pair-saved",
           !hasActiveConnection,
           !bleHandoffRunning {
            scheduleReconnect(reason: "watch-direct-disabled", immediate: true)
        }
    }

    private func pausePhoneConnectionForWatch(reason: String) {
        autoReconnectEnabled = false
        pendingReconnectReason = nil
        pendingReconnectPeripheral = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        postAuthListenTask?.cancel()
        postAuthListenTask = nil
        postAuthListenerGeneration += 1
        reconnectStatus = "ceded to watch"
        bleHandoffStatus = "Cedat către Apple Watch"

        guard let session = activeSession else {
            appendLifecycleEvent("phone connection ceded to watch reason=\(reason) no-active-session")
            clearActiveSession(resetTarget: false)
            return
        }

        appendLifecycleEvent("phone connection ceded to watch reason=\(reason) target=\(activeConnectionDisplay)")
        scanner.disconnect(session)
        clearActiveSession(resetTarget: false)
    }

    func registerWakeEvents() {
        registerWakeEventsForCurrentSession(reason: "manual")
    }

    private func registerWakeEventsForCurrentSession(reason: String) {
        let wakePeripheralID = activePeripheralID ?? targetPeripheralID
        let ids = wakePeripheralID.map { [$0] }
        scanner.registerForConnectionEvents(
            peripheralIDs: ids,
            serviceUUIDs: [LibreSensorGATT.serviceUUID]
        )
        appendLifecycleEvent(
            "registered connection events reason=\(reason) peripheral=" +
            "\(wakePeripheralID?.uuidString ?? "any") service=\(LibreSensorGATT.serviceUUID.uuidString)"
        )
    }

    func clearDecodedData() {
        latestGlucose = nil
        glucoseReadings.removeAll()
        latestPatchStatus = nil
        historicalBackfill = HistoricalBackfill()
        recentDecodedPackets.removeAll()
        appendLifecycleEvent("decoded data cleared")
    }

    func copyLifecycleEventsToPasteboard() {
        let text = lifecycleEvents
            .map(\.summary)
            .joined(separator: "\n")
#if canImport(UIKit)
        UIPasteboard.general.string = text
        appendLifecycleEvent("copied \(lifecycleEvents.count) lifecycle events")
#else
        _ = text
#endif
    }

    var historicalBackfillRangeDisplay: String {
        guard let first = historicalBackfill.firstLifeCount,
              let last = historicalBackfill.lastLifeCount else {
            return "none"
        }
        return "\(first)...\(last)"
    }

    var historicalBackfillGapDisplay: String {
        historicalBackfill.gaps.isEmpty
            ? "none"
            : historicalBackfill.gaps
                .prefix(4)
                .map { "\($0.afterLifeCount)->\($0.beforeLifeCount)" }
                .joined(separator: ",")
    }

    func recordScenePhase(_ phase: ScenePhase) {
        let display: String
        switch phase {
        case .active:
            display = "active"
        case .inactive:
            display = "inactive"
        case .background:
            display = "background"
        @unknown default:
            display = "unknown"
        }
        latestScenePhase = display
        appendLifecycleEvent("scene \(display)")
        if phase == .active {
            handleSceneBecameActive()
        }
    }

    private func handleSceneBecameActive() {
        guard autoReconnectEnabled || desiredSensorState != nil || persistedSensorState != nil else {
            return
        }
        if hasActiveConnection {
            refreshActiveDataPlane(reason: "foreground")
        } else {
            requestReconnect(reason: "foreground-active-no-session", immediate: true)
        }
    }

    private func refreshActiveDataPlane(reason: String) {
        guard let session = activeSession, let material = activeSessionMaterial else {
            requestReconnect(reason: "\(reason)-missing-session-material", immediate: true)
            return
        }
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { @MainActor [weak self, session, material] in
            guard let self else { return }
            do {
                let crypto = try DataPlaneCrypto(sessionMaterial: material)
                self.appendLifecycleEvent("foreground data-plane refresh reason=\(reason)")
                if self.postAuthListenTask == nil {
                    self.startPersistentPostAuthListener(
                        session: session,
                        crypto: crypto,
                        counter: FirstPairPostAuthCounter(),
                        reason: "\(reason)-listener-restart"
                    )
                }
                await self.refreshFirstPairPostAuthNotifications(via: session)
                await self.readFirstPairPatchStatus(via: session, crypto: crypto)
                self.reconnectStatus = "active session refreshed"
            } catch {
                self.appendLifecycleEvent("foreground refresh failed: \(String(describing: error))")
                self.requestReconnect(reason: "\(reason)-refresh-failed", immediate: true)
            }
            self.foregroundRefreshTask = nil
        }
    }

    private func requestReconnect(
        reason: String,
        preferredPeripheral: CBPeripheral? = nil,
        immediate: Bool = false
    ) {
        if let preferredPeripheral {
            pendingReconnectPeripheral = preferredPeripheral
            targetPeripheralID = preferredPeripheral.identifier
        }
        guard autoReconnectEnabled else {
            appendLifecycleEvent("reconnect ignored reason=\(reason) autoReconnect=false")
            return
        }
        guard desiredSensorState ?? persistedSensorState ?? activatedSensorState != nil else {
            appendLifecycleEvent("reconnect ignored reason=\(reason) no saved sensor state")
            return
        }
        if bleHandoffRunning {
            pendingReconnectReason = reason
            reconnectStatus = "pending: \(reason)"
            appendLifecycleEvent("reconnect pending reason=\(reason)")
            return
        }
        scheduleReconnect(reason: reason, preferredPeripheral: preferredPeripheral, immediate: immediate)
    }

    private func scheduleReconnect(
        reason: String,
        preferredPeripheral: CBPeripheral? = nil,
        immediate: Bool = false
    ) {
        guard reconnectTask == nil else {
            appendLifecycleEvent("reconnect already scheduled reason=\(reason)")
            return
        }
        guard let state = desiredSensorState ?? persistedSensorState ?? activatedSensorState else {
            appendLifecycleEvent("reconnect schedule skipped reason=\(reason) no saved sensor state")
            return
        }

        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = immediate ? 0 : Self.reconnectDelay(forAttempt: attempt)
        reconnectStatus = delay > 0
            ? "scheduled in \(Int(delay))s (\(reason))"
            : "scheduled now (\(reason))"
        registerWakeEventsForCurrentSession(reason: "reconnect-scheduled")
        appendLifecycleEvent(
            "reconnect scheduled attempt=\(attempt) delay=\(Int(delay))s reason=\(reason)"
        )

        reconnectTask = Task { @MainActor [weak self, state, preferredPeripheral] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            let directPeripheral = preferredPeripheral ?? self.pendingReconnectPeripheral
            self.pendingReconnectPeripheral = nil
            self.reconnectTask = nil
            self.startBLEHandoff(
                with: state,
                reason: "auto-reconnect:\(reason)",
                preferredPeripheral: directPeripheral
            )
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

    private func sensorStateFileURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libre3SensorState.json")
    }

    private func loadPersistedSensorState(reportMissing: Bool = false) {
        let url = sensorStateFileURL()
        savedSensorStateURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        guard let data = try? Data(contentsOf: url) else {
            persistedSensorState = nil
            if reportMissing {
                appendLifecycleEvent("no saved sensor state found")
            }
            return
        }
        do {
            let state = try Libre3SensorStateLoader.load(fromJSON: data)
            persistedSensorState = state
            desiredSensorState = state
            WatchSensorStateSyncCoordinator.shared.publish(state, guaranteeDelivery: true)
            autoReconnectEnabled = autoConnectSavedState && !watchDirectConnectionEnabled
            reconnectStatus = watchDirectConnectionEnabled
                ? "watch direct enabled"
                : (autoConnectSavedState ? "loaded saved state" : "saved-state auto-connect disabled")
            savedSensorStateURL = url
            appendLifecycleEvent(
                "loaded saved state serial=\(state.serialNumber ?? "") " +
                "ble=\(state.bleAddress ?? "") receiverID=\(state.receiverID?.littleEndianHex ?? "nil") " +
                "lastGlucoseLC=\(state.lastGlucoseLifeCount.map(String.init) ?? "nil")"
            )
        } catch {
            persistedSensorState = nil
            lastError = "Saved sensor state: \(error)"
            appendLifecycleEvent("saved state load failed: \(String(describing: error))")
        }
    }

    private func observeScannerLifecycle() {
        Task { [weak self] in
            guard let self else { return }
            for await event in self.scanner.restorationEvents() {
                self.handleRestorationEvent(event)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await state in self.scanner.stateEvents() {
                self.appendLifecycleEvent("central state \(Self.centralStateName(state))")
                guard state == .poweredOn else {
                    continue
                }
                self.registerWakeEventsForCurrentSession(reason: "central-powered-on")
                if self.autoReconnectEnabled,
                   !self.hasActiveConnection,
                   !self.bleHandoffRunning {
                    self.requestReconnect(reason: "central-powered-on", immediate: true)
                } else if self.hasActiveConnection {
                    self.refreshActiveDataPlane(reason: "central-powered-on")
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await event in self.scanner.connectionEvents() {
                let name = event.peripheral.name ?? String(event.peripheral.identifier.uuidString.prefix(8))
                self.appendLifecycleEvent(
                    "connectionEvent \(Self.connectionEventName(event.event)) target=\(name)"
                )
                switch event.event {
                case .peerConnected:
                    self.requestReconnect(
                        reason: "connection-event-peerConnected",
                        preferredPeripheral: event.peripheral,
                        immediate: true
                    )
                case .peerDisconnected:
                    let isTrackedPeripheral =
                        event.peripheral.identifier == self.activePeripheralID ||
                        event.peripheral.identifier == self.targetPeripheralID
                    if isTrackedPeripheral {
                        self.requestReconnect(
                            reason: "connection-event-peerDisconnected",
                            preferredPeripheral: event.peripheral,
                            immediate: false
                        )
                    }
                @unknown default:
                    break
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await event in self.scanner.disconnectionEvents() {
                self.handleDisconnectionEvent(event)
            }
        }
    }

    private func handleRestorationEvent(_ event: SensorRestorationEvent) {
        let peripheralIDs = event.peripherals
            .map { String($0.identifier.uuidString.prefix(8)) }
            .joined(separator: ",")
        let services = event.scanServices
            .map(\.uuidString)
            .joined(separator: ",")
        appendLifecycleEvent(
            "restored peripherals=[\(peripheralIDs)] scanServices=[\(services)]"
        )

        guard let peripheral = event.peripherals.first else {
            requestReconnect(reason: "central-restore-no-peripheral", immediate: true)
            return
        }

        targetPeripheralID = peripheral.identifier
        pendingReconnectPeripheral = peripheral
        registerWakeEventsForCurrentSession(reason: "central-restore")
        requestReconnect(
            reason: "central-restore",
            preferredPeripheral: peripheral,
            immediate: true
        )
    }

    private func handleDisconnectionEvent(_ event: SensorDisconnectionEvent) {
        let name = event.peripheral.name ?? String(event.peripheral.identifier.uuidString.prefix(8))
        let trackedByID =
            event.peripheral.identifier == activePeripheralID ||
            event.peripheral.identifier == targetPeripheralID
        let targetName = Self.normalizedBLEAddress(
            (desiredSensorState ?? persistedSensorState ?? activatedSensorState)?.bleAddress
        )
        let trackedByName =
            targetName != nil &&
            Self.normalizedBLEAddress(event.peripheral.name) == targetName
        appendLifecycleEvent(
            "didDisconnect target=\(name) tracked=\(trackedByID || trackedByName) " +
            "error=\(event.error?.localizedDescription ?? "nil")"
        )
        guard trackedByID || trackedByName else {
            return
        }

        targetPeripheralID = event.peripheral.identifier
        pendingReconnectPeripheral = event.peripheral
        registerWakeEventsForCurrentSession(reason: "did-disconnect")
        clearActiveSession(resetTarget: false)
        requestReconnect(
            reason: "did-disconnect",
            preferredPeripheral: event.peripheral,
            immediate: false
        )
    }

    private func appendLifecycleEvent(_ message: String) {
        lifecycleEvents.append(LifecycleEventDisplay(occurredAt: Date(), message: message))
        if lifecycleEvents.count > 40 {
            lifecycleEvents.removeFirst(lifecycleEvents.count - 40)
        }
        appendHandoffLog("lifecycle \(message)")
    }

    private func setActiveSession(_ session: SensorSession, name: String) {
        activeSession = session
        activePeripheralID = session.peripheral.identifier
        targetPeripheralID = session.peripheral.identifier
        activePeripheralName = name
        hasActiveConnection = true
        activeConnectionDisplay = "\(name) \(String(session.peripheral.identifier.uuidString.prefix(8)))"
        appendLifecycleEvent("connected target=\(activeConnectionDisplay)")
        registerWakeEventsForCurrentSession(reason: "connected")
    }

    private func clearActiveSession(resetTarget: Bool = false) {
        activeSession = nil
        activePeripheralID = nil
        activePeripheralName = nil
        activeSessionMaterial = nil
        hasActiveConnection = false
        activeConnectionDisplay = "none"
        if resetTarget {
            targetPeripheralID = nil
        }
    }

    private func recordDecodedPacket(
        _ packet: DataPlaneDecodedPacket,
        channelName: String,
        receivedAt: Date
    ) {
        let sequence = packet.frame.sequenceNumber
        let kind = packet.usedPreferredKind ? "\(packet.kind.rawValue)" : "\(packet.kind.rawValue) fallback"
        var summary = "\(channelName) seq=\(String(format: "0x%04x", sequence)) kind=\(kind)"
        switch packet.payload {
        case .realtimeGlucose(let reading):
            let item = GlucoseDisplay(
                receivedAt: receivedAt,
                sequenceNumber: sequence,
                lifeCount: reading.lifeCount,
                currentGlucoseMgDL: reading.currentGlucoseMgDL,
                rateOfChangeMgDLPerMinute: reading.rateOfChangeMgDLPerMinute,
                trend: reading.trend,
                statusBits: reading.statusBits,
                historicalLifeCount: reading.historicalLifeCount,
                historicalGlucoseMgDL: reading.historicalGlucoseMgDL,
                temperatureRaw: reading.temperature,
                fastDataWordsLE: reading.fastDataWordsLE,
                plaintextHex: Self.hex(packet.plaintext)
            )
            latestGlucose = item
            glucoseReadings.insert(item, at: 0)
            if glucoseReadings.count > 36 {
                glucoseReadings.removeLast(glucoseReadings.count - 36)
            }
            if reading.isCurrentGlucoseUsable {
                readingStore.record(
                    item,
                    sensorSerialNumber: (persistedSensorState ?? activatedSensorState ?? desiredSensorState)?.serialNumber
                )
            }
            persistLastGlucose(lifeCount: reading.lifeCount, mgDL: reading.currentGlucoseMgDL)
            summary += " glucose=\(item.currentDisplay) rate=\(item.rateDisplay) tempRaw=\(item.temperatureRaw)"

        case .patchStatus(let status):
            let lifecycle = status.lifecycle(
                wearDurationMinutes: patchInfo.map { Int($0.wearDurationMinutes) }
            )
            let item = PatchStatusDisplay(
                receivedAt: receivedAt,
                sequenceNumber: sequence,
                patchState: status.patchState,
                patchStateKind: status.patchStateKind,
                currentLifeCount: status.currentLifeCount,
                lifecyclePhase: lifecycle.phase.rawValue,
                remainingWarmupMinutes: lifecycle.remainingWarmupMinutes,
                remainingWearMinutes: lifecycle.remainingWearMinutes,
                totalEvents: status.totalEvents,
                stackDisconnectReason: status.stackDisconnectReason,
                appDisconnectReason: status.appDisconnectReason
            )
            latestPatchStatus = item
            summary += " patchState=\(status.patchState) lc=\(status.currentLifeCount)"

        case .historicalReadingPage(let page):
            var updatedBackfill = historicalBackfill
            updatedBackfill.append(page)
            historicalBackfill = updatedBackfill
            let values = page.values.map(String.init).joined(separator: ",")
            summary += " histLC=\(page.startLifeCount)..\(page.endLifeCount) values=[\(values)]"

        case .clinicalReadingRecord(let record):
            let current = record.currentGlucoseMgDL.map(String.init) ?? "invalid"
            let historic = record.historicGlucoseMgDL.map(String.init) ?? "invalid"
            let historicLifeCount = record.historicLifeCountEstimate.map(String.init) ?? "unknown"
            summary += " clinicalLC=\(record.lifeCount) current=\(current) " +
                "historicLC=\(historicLifeCount) historic=\(historic)"

        case .raw:
            summary += " pt=\(Self.hex(packet.plaintext))"
        }

        recentDecodedPackets.insert(
            DecodedPacketDisplay(receivedAt: receivedAt, summary: summary),
            at: 0
        )
        if recentDecodedPackets.count > 48 {
            recentDecodedPackets.removeLast(recentDecodedPackets.count - 48)
        }
    }

    private func startBLEHandoff(
        with state: Libre3SensorState,
        reason: String,
        preferredPeripheral: CBPeripheral? = nil
    ) {
        desiredSensorState = state
        guard state.phase5RawKey != nil || sendCandidatePhase5 else {
            autoReconnectEnabled = false
            pendingReconnectReason = nil
            pendingReconnectPeripheral = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            bleHandoffRunning = false
            bleHandoffStatus = "Missing Phase 5 key"
            reconnectStatus = "blocked: missing Phase 5 key"
            lastError = Self.missingPhase5RawKeyMessage(for: state)
            appendHandoffLog(
                "BLE handoff blocked reason=\(reason) missing phase5RawKey " +
                "serial=\(state.serialNumber ?? "") ble=\(state.bleAddress ?? "") " +
                "receiverID=\(state.receiverID?.littleEndianHex ?? "nil")"
            )
            return
        }
        if watchDirectConnectionEnabled {
            autoReconnectEnabled = false
            WatchSensorStateSyncCoordinator.shared.publish(state, guaranteeDelivery: true)
            bleHandoffStatus = "Cedat către Apple Watch"
            reconnectStatus = "ceded to watch"
            appendLifecycleEvent("BLE handoff skipped for Apple Watch reason=\(reason)")
            pausePhoneConnectionForWatch(reason: "watch-direct:\(reason)")
            return
        }
        autoReconnectEnabled = true
        if let preferredPeripheral {
            pendingReconnectPeripheral = preferredPeripheral
            targetPeripheralID = preferredPeripheral.identifier
        }
        guard !bleHandoffRunning else {
            pendingReconnectReason = reason
            reconnectStatus = "pending: \(reason)"
            appendLifecycleEvent("BLE handoff already running; pending reconnect reason=\(reason)")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        bleHandoffRunning = true
        bleHandoffStatus = "Waiting for Bluetooth"
        reconnectStatus = "handoff running (\(reason))"
        bleBootstrapSummary = nil
        appendHandoffLog(
            "BLE pairing started reason=\(reason) serial=\(state.serialNumber ?? "") " +
            "ble=\(state.bleAddress ?? "") blePIN=\(Self.hex(state.blePIN))"
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.runBLEHandoff(
                    state: state,
                    preferredPeripheral: preferredPeripheral
                )
                self.bleBootstrapSummary = summary
                self.appendHandoffLog("BLE pairing succeeded\n\(summary)")
                if self.watchDirectConnectionEnabled {
                    self.pausePhoneConnectionForWatch(reason: "handoff-complete")
                } else {
                    self.bleHandoffStatus = self.sendCandidatePhase5
                        ? "Pairing complete"
                        : "Pairing preamble complete"
                    self.reconnectStatus = "connected"
                    self.reconnectAttempt = 0
                }
            } catch {
                self.lastError = "BLE pairing: \(error)"
                self.bleHandoffStatus = "BLE pairing failed"
                self.appendHandoffLog("BLE pairing failed error=\(String(describing: error))")
                self.clearActiveSession(resetTarget: false)
                self.registerWakeEventsForCurrentSession(reason: "handoff-failed")
                if !self.watchDirectConnectionEnabled &&
                    self.autoReconnectEnabled &&
                    (self.sendCandidatePhase5 ||
                        self.dataPlaneSessionEstablished ||
                        reason.hasPrefix("auto-reconnect")) {
                    self.scheduleReconnect(reason: "handoff-failed:\(reason)", immediate: false)
                } else {
                    self.reconnectStatus = "failed"
                }
            }
            self.bleHandoffRunning = false
            if let pending = self.pendingReconnectReason {
                self.pendingReconnectReason = nil
                self.requestReconnect(reason: pending, immediate: false)
            }
        }
    }

    private func runBLEHandoff(
        state: Libre3SensorState,
        preferredPeripheral: CBPeripheral? = nil
    ) async throws -> String {
        try await scanner.waitUntilReady()
        bleHandoffStatus = "Scanning for Libre 3 service"
        let targetBLEName = Self.normalizedBLEAddress(state.bleAddress)

        if let preferredPeripheral {
            do {
                let directState = await scanner.state(of: preferredPeripheral)
                if directState != .disconnected {
                    appendHandoffLog(
                        "BLE clearing event peripheral " +
                        "id=\(String(preferredPeripheral.identifier.uuidString.prefix(8))) " +
                        "state=\(directState.rawValue)"
                    )
                    await scanner.ensureDisconnected(peripheralID: preferredPeripheral.identifier)
                }
                return try await connectAndRunFirstPairPreamble(
                    peripheral: preferredPeripheral,
                    state: state,
                    targetName: preferredPeripheral.name ?? String(preferredPeripheral.identifier.uuidString.prefix(8)),
                    targetRSSI: nil,
                    source: "event-peripheral",
                    connectTimeout: knownPeripheralConnectTimeout
                )
            } catch {
                await scanner.ensureDisconnected(peripheralID: preferredPeripheral.identifier)
                if targetPeripheralID == preferredPeripheral.identifier {
                    targetPeripheralID = nil
                }
                appendHandoffLog(
                    "BLE event-peripheral reconnect failed target=" +
                    "\(preferredPeripheral.name ?? String(preferredPeripheral.identifier.uuidString.prefix(8))) " +
                    "error=\(String(describing: error)); falling back to scan"
                )
            }
        }

        if let connected = await reconnectPeripheral(targetBLEName: targetBLEName) {
            do {
                return try await connectAndRunFirstPairPreamble(
                    peripheral: connected,
                    state: state,
                    targetName: connected.name ?? String(connected.identifier.uuidString.prefix(8)),
                    targetRSSI: nil,
                    source: "already-connected",
                    connectTimeout: knownPeripheralConnectTimeout
                )
            } catch {
                await scanner.ensureDisconnected(peripheralID: connected.identifier)
                if targetPeripheralID == connected.identifier {
                    targetPeripheralID = nil
                }
                appendHandoffLog(
                    "BLE already-connected reuse failed target=" +
                    "\(connected.name ?? String(connected.identifier.uuidString.prefix(8))) " +
                    "error=\(String(describing: error)); falling back to scan"
                )
            }
        }

        appendHandoffLog("BLE scan started timeout=\(Int(bleScanTimeout))s")
        let discovered = try await firstLibreDiscovery(timeout: bleScanTimeout, targetBLEName: targetBLEName)
        let name = discovered.name ?? String(discovered.id.uuidString.prefix(8))
        appendHandoffLog("BLE discovered target=\(name) rssi=\(discovered.rssi)")
        return try await connectAndRunFirstPairPreamble(
            peripheral: discovered.peripheral,
            state: state,
            targetName: name,
            targetRSSI: discovered.rssi,
            source: "scan",
            connectTimeout: discoveredPeripheralConnectTimeout
        )
    }

    private func firstPairNativeEphemeral(
        for state: Libre3SensorState
    ) async throws -> FirstPairNativeEphemeralMaterial {
        let sensorKey = [
            Self.normalizedBLEAddress(state.bleAddress) ?? "",
            state.serialNumber ?? "",
        ].joined(separator: "|")
        if let cached = cachedFirstPairNativeEphemeral,
           cached.sensorKey == sensorKey {
            appendHandoffLog(
                "First-pair native phone ephemeral reused attempts=\(cached.material.attempts) " +
                "pub=\(Self.hex(cached.material.keyPair.publicKey65))"
            )
            return cached.material
        }

        bleHandoffStatus = "Preparing first-pair material"
        let material = try await Task.detached(priority: .userInitiated) {
            try SessionKey.makeFirstPairNativeEphemeral { requestedCount in
                try Self.secureRandomData(count: requestedCount)
            }
        }.value
        cachedFirstPairNativeEphemeral = (sensorKey, material)
        appendHandoffLog(
            "First-pair native phone ephemeral prepared attempts=\(material.attempts) " +
            "pub=\(Self.hex(material.keyPair.publicKey65))"
        )
        return material
    }

    private func reconnectPeripheral(targetBLEName: String?) async -> CBPeripheral? {
        let connected = await scanner.retrieveConnectedPeripherals()
        if let targetBLEName {
            return connected.first { Self.normalizedBLEAddress($0.name) == targetBLEName }
        }
        return connected.first
    }

    private func connectAndRunFirstPairPreamble(
        peripheral: CBPeripheral,
        state: Libre3SensorState,
        targetName: String,
        targetRSSI: Int?,
        source: String,
        connectTimeout: TimeInterval
    ) async throws -> String {
        bleHandoffStatus = "Connecting to \(targetName)"
        appendHandoffLog(
            "BLE connect source=\(source) target=\(targetName) " +
            "id=\(String(peripheral.identifier.uuidString.prefix(8))) " +
            "timeout=\(Int(connectTimeout))s"
        )
        let session = try await scanner.connect(peripheral, timeout: connectTimeout)
        bleHandoffStatus = "Connected; running first-pair preamble"
        appendHandoffLog("BLE connected target=\(targetName)")
        setActiveSession(session, name: targetName)
        do {
            return try await runFirstPairPreamble(
                session: session,
                state: state,
                targetName: targetName,
                targetRSSI: targetRSSI
            )
        } catch {
            appendHandoffLog(
                "BLE authorization failed; disconnecting before retry " +
                "target=\(targetName) error=\(String(describing: error))"
            )
            session.handleDisconnect(error: error)
            scanner.disconnect(session)
            await scanner.ensureDisconnected(peripheralID: session.peripheral.identifier)
            clearActiveSession(resetTarget: false)
            throw error
        }
    }

    private func firstLibreDiscovery(timeout: TimeInterval, targetBLEName: String?) async throws -> DiscoveredSensor {
        // Shared scan/match/broad-fallback policy lives in the kit so the iOS
        // and Watch apps follow one identical discovery flow. The scanner logs
        // every sighting and the eventual match through the BLE event logger.
        let found = try await scanner.discoverFirstSensor(
            targetName: targetBLEName,
            timeout: timeout
        )
        if let targetBLEName,
           Self.normalizedBLEAddress(found.name) != targetBLEName {
            appendHandoffLog(
                "BLE using fallback Libre discovery " +
                "target=\(targetBLEName) found=\(found.name ?? String(found.id.uuidString.prefix(8))) " +
                "rssi=\(found.rssi)"
            )
        }
        return found
    }

    private func runFirstPairPreamble(
        session: SensorSession,
        state: Libre3SensorState,
        targetName: String,
        targetRSSI: Int?
    ) async throws -> String {
        appendHandoffLog(
            "Authorization flow started sendCandidatePhase5=\(sendCandidatePhase5) " +
            "hasCachedPhase5=\(state.phase5RawKey != nil) " +
            "fastCachedReconnect=\(enableFastCachedReconnect)"
        )
        let eventLogger = makeHandoffEventLogger()
        let transport = SensorSessionTransport(session: session, eventLogger: eventLogger)
        if enableFastCachedReconnect, let phase5RawKey = state.phase5RawKey {
            do {
                let cachedFlow = PairingFlow(
                    transport: transport,
                    eventLogger: eventLogger
                )
                let summary = try await runCachedReconnectHandshake(
                    flow: cachedFlow,
                    session: session,
                    phase5RawKey: phase5RawKey,
                    state: state,
                    targetName: targetName,
                    targetRSSI: targetRSSI
                )
                cachedReconnectFailureStreak = 0
                return summary
            } catch {
                cachedReconnectFailureStreak += 1
                appendHandoffLog(
                    "Cached reconnect failed (streak=\(cachedReconnectFailureStreak)); " +
                    "keeping cached key for fast retry error=\(String(describing: error))"
                )
                // NOTE: we deliberately do NOT retire the cached key here. The
                // candidate first-pair fallback is a dead end on an already-paired
                // sensor — its ~30s clean-room Phase 5 derivation runs with no BLE
                // traffic and trips the sensor's supervision timeout before Phase 5
                // is even sent. Dropping the cached key only loses a (possibly
                // recoverable/correct) key and forces that doomed slow path. The
                // fast cached path is harmless to retry; a wrong key is fixed by
                // pasting the real one via manual import (recovery field).
                throw error
            }
        }

        let nativeEphemeral = try await firstPairNativeEphemeral(for: state)
        let phoneCert = try loadPhoneCert()
        appendHandoffLog("First-pair phone cert=\(phoneCert.label) len=\(phoneCert.cert.raw.count)")
        appendHandoffLog(
            "First-pair native phone ephemeral attempts=\(nativeEphemeral.attempts) " +
            "pub=\(Self.hex(nativeEphemeral.keyPair.publicKey65))"
        )
        let flow = PairingFlow(
            transport: transport,
            phoneCert: phoneCert.cert,
            phoneEph: nativeEphemeral.keyPair,
            eventLogger: eventLogger
        )
        if let phase5RawKey = state.phase5RawKey {
            return try await runCommandGatedSavedStateHandshake(
                flow: flow,
                session: session,
                phase5RawKey: phase5RawKey,
                state: state,
                targetName: targetName,
                targetRSSI: targetRSSI,
                phoneEphPub: nativeEphemeral.keyPair.publicKey65
            )
        }
        guard sendCandidatePhase5 else {
            throw NFCActivationHandoffError.missingPhase5RawKey
        }
        return try await runFirstPairCandidateHandshake(
            flow: flow,
            session: session,
            nativeEphemeral: nativeEphemeral,
            state: state,
            targetName: targetName,
            targetRSSI: targetRSSI
        )
    }

    private func runCachedReconnectHandshake(
        flow: PairingFlow,
        session: SensorSession,
        phase5RawKey: Data,
        state: Libre3SensorState,
        targetName: String,
        targetRSSI: Int?
    ) async throws -> String {
        bleHandoffStatus = "Running cached reconnect"
        appendHandoffLog(
            "Cached reconnect started rawKey=\(Self.hex(phase5RawKey)) " +
            "lastGlucoseLC=\(state.lastGlucoseLifeCount.map(String.init) ?? "nil")"
        )
        let result = try await flow.runCachedReconnectHandshake(
            tail4: state.blePIN,
            phase5RawKey: phase5RawKey,
            r2Provider: {
                try Self.secureRandomData(count: 16)
            },
            commandTimeout: 2,
            notifyTimeout: 12
        )
        let phase6NoncePrefix = Self.phase6NoncePrefix(fromNonce: result.phase6.nonce)
        let historyStart = Self.historyBackfillStart(
            phase6NoncePrefix: phase6NoncePrefix,
            savedLastLifeCount: state.lastGlucoseLifeCount
        )
        bleHandoffStatus = "Cached reconnect complete; listening for data"
        let postAuthSummary = try await runFirstPairPostAuthData(
            session: session,
            material: result.sessionMaterial,
            historicalLifeCount: historyStart,
            savedLastGlucoseLifeCount: state.lastGlucoseLifeCount
        )

        return ([
            "target=\(targetName) rssi=\(targetRSSI.map(String.init) ?? "unknown")",
            "authorization=cached-reconnect",
            "nfcSerial=\(state.serialNumber ?? "")",
            "nfcBLE=\(state.bleAddress ?? "")",
            "blePIN=\(Self.hex(state.blePIN))",
            "cachedPhase5RawKey=\(Self.hex(phase5RawKey))",
            "R1=\(Self.hex(result.preamble.sensorR1))",
            "nonce7=\(Self.hex(result.preamble.nonce7))",
            "phase5=sent-cached",
            "phase5Wire=\(Self.hex(result.phase5Sent.logicalBytes))",
            "phase6Raw=\(Self.hex(result.phase6Raw))",
            "phase6NonceU16LE=\(phase6NoncePrefix.map(String.init) ?? "nil")",
            "savedLastGlucoseLC=\(state.lastGlucoseLifeCount.map(String.init) ?? "nil")",
            "historyBackfillStart=\(historyStart)",
            "sessionKEnc=\(Self.hex(result.sessionMaterial.kEnc))",
            "sessionIVEnc8=\(Self.hex(result.sessionMaterial.ivEnc))",
        ] + postAuthSummary).joined(separator: "\n")
    }

    private func runCommandGatedSavedStateHandshake(
        flow: PairingFlow,
        session: SensorSession,
        phase5RawKey: Data,
        state: Libre3SensorState,
        targetName: String,
        targetRSSI: Int?,
        phoneEphPub: Data
    ) async throws -> String {
        bleHandoffStatus = "Running saved-state authorization"
        appendHandoffLog(
            "Saved-state command-gated authorization started rawKey=\(Self.hex(phase5RawKey))"
        )
        let handshake = try await flow.runCommandGatedAuthorizationHandshake(
            tail4: state.blePIN,
            phase5RawKeyProvider: { _ in phase5RawKey },
            r2Provider: {
                try Self.secureRandomData(count: 16)
            },
            commandTimeout: 2,
            notifyTimeout: 12
        )
        let phase6NoncePrefix = Self.phase6NoncePrefix(fromNonce: handshake.phase6.nonce)
        let historyStart = Self.historyBackfillStart(
            phase6NoncePrefix: phase6NoncePrefix,
            savedLastLifeCount: state.lastGlucoseLifeCount
        )
        bleHandoffStatus = "Saved-state authorization complete; listening for data"
        let postAuthSummary = try await runFirstPairPostAuthData(
            session: session,
            material: handshake.sessionMaterial,
            historicalLifeCount: historyStart,
            savedLastGlucoseLifeCount: state.lastGlucoseLifeCount
        )

        return ([
            "target=\(targetName) rssi=\(targetRSSI.map(String.init) ?? "unknown")",
            "authorization=command-gated-saved-state",
            "nfcSerial=\(state.serialNumber ?? "")",
            "nfcBLE=\(state.bleAddress ?? "")",
            "blePIN=\(Self.hex(state.blePIN))",
            "cachedPhase5RawKey=\(Self.hex(phase5RawKey))",
            "sensorCert=\(handshake.preamble.phaseHandshake.sensorCert.raw.count)B " +
                "sensorEph=\(handshake.preamble.phaseHandshake.sensorEphPub.x963Representation.count)B",
            "S_eph_static=\(Self.hex(handshake.preamble.phaseHandshake.sharedEphStatic))",
            "S_eph_eph=\(Self.hex(handshake.preamble.phaseHandshake.sharedEphEph))",
            "R1=\(Self.hex(handshake.preamble.sensorR1))",
            "nonce7=\(Self.hex(handshake.preamble.nonce7))",
            "phoneEphPub=\(Self.hex(phoneEphPub))",
            "phase5=sent-saved-state",
            "phase5Wire=\(Self.hex(handshake.phase5Sent.logicalBytes))",
            "phase6Raw=\(Self.hex(handshake.phase6Raw))",
            "phase6NonceU16LE=\(phase6NoncePrefix.map(String.init) ?? "nil")",
            "savedLastGlucoseLC=\(state.lastGlucoseLifeCount.map(String.init) ?? "nil")",
            "historyBackfillStart=\(historyStart)",
            "sessionKEnc=\(Self.hex(handshake.sessionMaterial.kEnc))",
            "sessionIVEnc8=\(Self.hex(handshake.sessionMaterial.ivEnc))",
        ] + postAuthSummary).joined(separator: "\n")
    }

    private func runFirstPairCandidateHandshake(
        flow: PairingFlow,
        session: SensorSession,
        nativeEphemeral: FirstPairNativeEphemeralMaterial,
        state: Libre3SensorState,
        targetName: String,
        targetRSSI: Int?
    ) async throws -> String {
        bleHandoffStatus = "Running candidate first-pair Phase 5"
        let result = try await flow.runCommandGatedFirstPairHandshake(
            blePIN: state.blePIN,
            maxEntropyAttempts: 1,
            entropySource: { requestedCount in
                try Self.fixedEntropySource(nativeEphemeral.nullEntropy11A, requestedCount: requestedCount)
            },
            r2Provider: {
                try Self.secureRandomData(count: 16)
            }
        )
        let handshake = result.handshake
        let phase5Material = result.phase5Material
        let staticScalarOverride = handshake.preamble.phaseHandshake.phoneCert.phase5StaticScalarWindowOverride
        let phase6NoncePrefix = Self.phase6NoncePrefix(fromNonce: handshake.phase6.nonce)
        let historyStart = Self.historyBackfillStart(
            phase6NoncePrefix: phase6NoncePrefix,
            savedLastLifeCount: state.lastGlucoseLifeCount
        )
        persistPhase5RawKey(phase5Material.rawKey, for: state)
        bleHandoffStatus = "Phase 6 complete; listening for data"
        let postAuthSummary = try await runFirstPairPostAuthData(
            session: session,
            material: handshake.sessionMaterial,
            historicalLifeCount: historyStart,
            savedLastGlucoseLifeCount: state.lastGlucoseLifeCount
        )

        return ([
            "target=\(targetName) rssi=\(targetRSSI.map(String.init) ?? "unknown")",
            "nfcSerial=\(state.serialNumber ?? "")",
            "nfcBLE=\(state.bleAddress ?? "")",
            "blePIN=\(Self.hex(state.blePIN))",
            "sensorCert=\(handshake.preamble.phaseHandshake.sensorCert.raw.count)B " +
                "sensorEph=\(handshake.preamble.phaseHandshake.sensorEphPub.x963Representation.count)B",
            "S_eph_static=\(Self.hex(handshake.preamble.phaseHandshake.sharedEphStatic))",
            "S_eph_eph=\(Self.hex(handshake.preamble.phaseHandshake.sharedEphEph))",
            "R1=\(Self.hex(handshake.preamble.sensorR1))",
            "nonce7=\(Self.hex(handshake.preamble.nonce7))",
            "phoneEphPub=\(Self.hex(nativeEphemeral.keyPair.publicKey65))",
            "candidateStaticScalarOverride=\(staticScalarOverride?.count ?? 0)B",
            "candidateNullAttempts=\(phase5Material.nullAttempts)",
            "nativeNullAttempts=\(nativeEphemeral.attempts)",
            "candidateNullEntropy11A=\(Self.hex(phase5Material.nullEntropy11A))",
            "candidateNullScalarWindow=\(Self.hex(phase5Material.nullScalarWindow))",
            "candidatePhase5Source66=\(Self.hex(phase5Material.source66))",
            "candidatePhase5RawKey=\(Self.hex(phase5Material.rawKey))",
            "phase5=sent",
            "phase5Wire=\(Self.hex(handshake.phase5Sent.logicalBytes))",
            "phase6Raw=\(Self.hex(handshake.phase6Raw))",
            "phase6NonceU16LE=\(phase6NoncePrefix.map(String.init) ?? "nil")",
            "savedLastGlucoseLC=\(state.lastGlucoseLifeCount.map(String.init) ?? "nil")",
            "historyBackfillStart=\(historyStart)",
            "sessionKEnc=\(Self.hex(handshake.sessionMaterial.kEnc))",
            "sessionIVEnc8=\(Self.hex(handshake.sessionMaterial.ivEnc))",
        ] + postAuthSummary).joined(separator: "\n")
    }

    private func runFirstPairPostAuthData(
        session: SensorSession,
        material: Phase6SessionMaterial,
        historicalLifeCount: UInt16,
        savedLastGlucoseLifeCount: UInt16?
    ) async throws -> [String] {
        let crypto = try DataPlaneCrypto(sessionMaterial: material)
        let counter = FirstPairPostAuthCounter()
        activeSessionMaterial = material
        autoReconnectEnabled = true
        dataPlaneSessionEstablished = true
        reconnectStatus = "data plane active"
        startPersistentPostAuthListener(
            session: session,
            crypto: crypto,
            counter: counter,
            reason: "phase6"
        )

        await refreshFirstPairPostAuthNotifications(via: session)
        guard await session.isConnected() else {
            throw SensorSessionError.disconnected(nil)
        }
        try await sendFirstPairPostAuthBootstrapCommands(
            via: session,
            crypto: crypto,
            counter: counter,
            historicalLifeCount: historicalLifeCount,
            savedLastGlucoseLifeCount: savedLastGlucoseLifeCount
        )
        await listenForFirstPairPostAuthData(
            via: session,
            crypto: crypto,
            counter: counter,
            duration: postAuthInitialListenDuration,
            patchStatusFallbackAfter: 75
        )
        let total = await counter.value()
        bleHandoffStatus = "First-pair data listener active"
        return ["postAuthDataNotifies=\(total)"]
    }

    private func startPersistentPostAuthListener(
        session: SensorSession,
        crypto: DataPlaneCrypto,
        counter: FirstPairPostAuthCounter,
        reason: String
    ) {
        postAuthListenTask?.cancel()
        postAuthListenerGeneration += 1
        let generation = postAuthListenerGeneration
        let assembler = DataPlaneNotificationAssembler()
        appendHandoffLog("post-auth data-plane listener started reason=\(reason)")
        postAuthListenTask = Task { [weak self, session, crypto, counter] in
            for await ev in session.notifications() {
                guard let channel = DataPlaneChannel(uuidString: ev.characteristic.uuidString) else {
                    continue
                }
                let count = await counter.mark(receivedAt: ev.receivedAt)
                let channelName = Self.dataPlaneChannelName(channel)
                await MainActor.run { [weak self] in
                    self?.appendHandoffLog(
                        "post-auth notify \(channelName) #\(count) " +
                        "len=\(ev.fragment.count) raw=\(Self.hex(ev.fragment))"
                    )
                }

                guard let frameRaw = assembler.feed(fragment: ev.fragment, channel: channel) else {
                    await MainActor.run { [weak self] in
                        self?.appendHandoffLog(
                            "post-auth \(channelName) partial \(ev.fragment.count)B buffered"
                        )
                    }
                    continue
                }

                do {
                    let frame = try DataFrame.parse(frameRaw)
                    let packet = try DataPlaneDecoder(crypto: crypto).decrypt(frame: frame, channel: channel)
                    let decoded = Self.decodedDataPlaneSummary(packet)
                    let fallback = packet.usedPreferredKind ? "" : " fallback"
                    await MainActor.run { [weak self] in
                        self?.recordDecodedPacket(
                            packet,
                            channelName: channelName,
                            receivedAt: ev.receivedAt
                        )
                        self?.appendHandoffLog(
                            "post-auth data \(channelName) " +
                            "seq=0x\(String(format: "%04x", frame.sequenceNumber)) " +
                            "kind=\(packet.kind.rawValue)\(fallback) " +
                            "pt(\(packet.plaintext.count)B)=\(Self.hex(packet.plaintext))" +
                            decoded
                        )
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.appendHandoffLog(
                            "post-auth data \(channelName) decrypt pending: \(String(describing: error))"
                        )
                    }
                }
            }

            guard !Task.isCancelled else { return }
            await counter.markStreamEnded()
            await MainActor.run { [weak self] in
                self?.handlePostAuthNotifyStreamEnded(generation: generation)
            }
        }
    }

    private func handlePostAuthNotifyStreamEnded(generation: Int) {
        guard generation == postAuthListenerGeneration else {
            appendLifecycleEvent("stale notify stream ended generation=\(generation)")
            return
        }
        appendHandoffLog("post-auth notify stream ended")
        appendLifecycleEvent("notify stream ended")
        postAuthListenTask = nil
        registerWakeEventsForCurrentSession(reason: "notify-stream-ended")
        clearActiveSession(resetTarget: false)
        requestReconnect(reason: "notify-stream-ended", immediate: false)
    }

    private func sendFirstPairPostAuthBootstrapCommands(
        via session: SensorSession,
        crypto: DataPlaneCrypto,
        counter: FirstPairPostAuthCounter,
        historicalLifeCount: UInt16,
        savedLastGlucoseLifeCount: UInt16?
    ) async throws {
        guard !skipPostAuthHistory else {
            appendHandoffLog("post-auth historical backfill disabled by --skip-post-auth-history")
            return
        }

        await setPostAuthNotification(
            true,
            name: "historicData",
            uuid: LibreSensorGATT.Char.historicData,
            via: session
        )
        let historicBaseline = await counter.value()
        do {
            try await sendFirstPairPatchControlCommand(
                .historicalBackfillGreaterEqual(lifeCount: historicalLifeCount),
                sequence: 0x0001,
                via: session,
                crypto: crypto,
                critical: true
            )
            await waitForFirstPairDataPlaneQuiet(
                label: "historicData",
                counter: counter,
                afterNotifyCount: historicBaseline,
                firstActivityTimeout: savedLastGlucoseLifeCount == nil ? 12 : 8,
                quietSeconds: savedLastGlucoseLifeCount == nil ? 3 : 2,
                maxSeconds: savedLastGlucoseLifeCount == nil ? 90 : 12
            )
        } catch {
            await setPostAuthNotification(
                false,
                name: "historicData",
                uuid: LibreSensorGATT.Char.historicData,
                via: session
            )
            throw error
        }
        await setPostAuthNotification(
            false,
            name: "historicData",
            uuid: LibreSensorGATT.Char.historicData,
            via: session
        )

        guard debugClinicalAfterHistory else {
            appendHandoffLog("post-auth clinical backfill disabled by default")
            return
        }

        await setPostAuthNotification(
            true,
            name: "clinicalData",
            uuid: LibreSensorGATT.Char.clinicalData,
            via: session
        )
        let clinicalBaseline = await counter.value()
        let sent = try await sendFirstPairPatchControlCommand(
            .clinicalBackfillGreaterEqual(lifeCount: historicalLifeCount),
            sequence: 0x0002,
            via: session,
            crypto: crypto,
            critical: false
        )
        if sent {
            await waitForFirstPairDataPlaneQuiet(
                label: "clinicalData",
                counter: counter,
                afterNotifyCount: clinicalBaseline,
                firstActivityTimeout: 8,
                quietSeconds: 3,
                maxSeconds: 30
            )
        }
        await setPostAuthNotification(
            false,
            name: "clinicalData",
            uuid: LibreSensorGATT.Char.clinicalData,
            via: session
        )
    }

    @discardableResult
    private func sendFirstPairPatchControlCommand(
        _ command: PatchControlCommand,
        sequence: UInt16,
        via session: SensorSession,
        crypto: DataPlaneCrypto,
        critical: Bool
    ) async throws -> Bool {
        let frame = try crypto.encrypt(
            plaintext: command.plaintext,
            sequence: sequence,
            kind: .patchControlWrite
        )
        appendHandoffLog(
            "post-auth patchControl \(command.label) " +
            "seq=0x\(String(format: "%04x", sequence)) " +
            "pt=\(Self.hex(command.plaintext)) raw=\(Self.hex(frame.raw))"
        )
        do {
            try await session.writeRaw(
                frame.raw,
                to: LibreSensorGATT.Char.patchControl,
                timeout: critical ? 10 : 8
            )
            appendHandoffLog("post-auth patchControl ACK")
            return true
        } catch {
            appendHandoffLog(
                "post-auth patchControl \(command.label) write not accepted: \(String(describing: error))"
            )
            if critical { throw error }
            return false
        }
    }

    private func waitForFirstPairDataPlaneQuiet(
        label: String,
        counter: FirstPairPostAuthCounter,
        afterNotifyCount baseline: Int,
        firstActivityTimeout: TimeInterval,
        quietSeconds: TimeInterval,
        maxSeconds: TimeInterval
    ) async {
        let start = Date()
        var sawActivity = (await counter.value()) > baseline
        var lastProgressLog = Date.distantPast

        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(start)
            let notifyCount = await counter.value()
            if notifyCount > baseline {
                sawActivity = true
            }

            if sawActivity, let last = await counter.lastNotifyAt() {
                let quietFor = now.timeIntervalSince(last)
                if quietFor >= quietSeconds {
                    appendHandoffLog(
                        "post-auth \(label) quiet for \(String(format: "%.1f", quietSeconds))s " +
                        "after \(notifyCount - baseline) notifies"
                    )
                    return
                }
            } else if elapsed >= firstActivityTimeout {
                appendHandoffLog(
                    "post-auth \(label) produced no data within " +
                    "\(String(format: "%.1f", firstActivityTimeout))s"
                )
                return
            }

            if elapsed >= maxSeconds {
                appendHandoffLog(
                    "post-auth \(label) still active after \(String(format: "%.1f", maxSeconds))s " +
                    "(\(max(0, notifyCount - baseline)) notifies); postponing later requests"
                )
                return
            }

            if now.timeIntervalSince(lastProgressLog) >= 15 {
                appendHandoffLog(
                    "post-auth waiting for \(label) quiet " +
                    "(\(max(0, notifyCount - baseline)) notifies so far)"
                )
                lastProgressLog = now
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func refreshFirstPairPostAuthNotifications(via session: SensorSession) async {
        let order: [(String, CBUUID)] = [
            ("glucoseData", LibreSensorGATT.Char.glucoseData),
            ("patchStatus", LibreSensorGATT.Char.patchStatus),
            ("historicData", LibreSensorGATT.Char.historicData),
            ("clinicalData", LibreSensorGATT.Char.clinicalData),
            ("eventLog", LibreSensorGATT.Char.eventLog),
            ("factoryData", LibreSensorGATT.Char.factoryData),
            ("patchControl", LibreSensorGATT.Char.patchControl),
        ]
        appendHandoffLog("post-auth data notification fast refresh")
        for (name, uuid) in order {
            guard await session.isConnected() else {
                appendHandoffLog("post-auth notification refresh stopped; peripheral disconnected")
                return
            }
            do {
                appendHandoffLog("post-auth notify \(name) re-arm")
                try await session.rearmNotifyBestEffort(for: uuid)
                appendHandoffLog("post-auth notify \(name) re-armed")
            } catch {
                appendHandoffLog("post-auth notify \(name) re-arm failed: \(String(describing: error))")
            }
        }
    }

    private func setPostAuthNotification(
        _ enabled: Bool,
        name: String,
        uuid: CBUUID,
        via session: SensorSession
    ) async {
        do {
            appendHandoffLog("post-auth notify \(name) \(enabled ? "on" : "off")")
            try await session.setNotify(enabled, for: uuid, timeout: 8)
            appendHandoffLog("post-auth notify \(name) \(enabled ? "enabled" : "disabled")")
            try await Task.sleep(nanoseconds: 90_000_000)
        } catch {
            appendHandoffLog(
                "post-auth notify \(name) \(enabled ? "enable" : "disable") failed: \(String(describing: error))"
            )
        }
    }

    private func listenForFirstPairPostAuthData(
        via session: SensorSession,
        crypto: DataPlaneCrypto,
        counter: FirstPairPostAuthCounter,
        duration: TimeInterval,
        patchStatusFallbackAfter: TimeInterval
    ) async {
        let baseline = await counter.value()
        let start = Date()
        var didPatchStatusFallback = false
        var lastProgressLog = Date.distantPast
        appendHandoffLog(
            "post-auth data listen for \(Int(duration))s; " +
            "patchStatus read fallback after \(Int(patchStatusFallbackAfter))s"
        )

        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(start)
            let newNotifies = max(0, await counter.value() - baseline)
            if await counter.isStreamEnded() {
                appendHandoffLog("post-auth data listen ended by notify stream newNotifies=\(newNotifies)")
                return
            }
            if elapsed >= duration {
                appendHandoffLog("post-auth data listen complete newNotifies=\(newNotifies)")
                return
            }

            if !didPatchStatusFallback && elapsed >= patchStatusFallbackAfter {
                didPatchStatusFallback = true
                if newNotifies == 0 {
                    await readFirstPairPatchStatus(via: session, crypto: crypto)
                } else {
                    appendHandoffLog("post-auth patchStatus read fallback skipped; data already active")
                }
            }

            if now.timeIntervalSince(lastProgressLog) >= 30 {
                appendHandoffLog("post-auth listen \(Int(elapsed))s newNotifies=\(newNotifies)")
                lastProgressLog = now
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func readFirstPairPatchStatus(via session: SensorSession, crypto: DataPlaneCrypto) async {
        appendHandoffLog("post-auth read patchStatus after one-minute quiet")
        do {
            let raw = try await session.readRaw(LibreSensorGATT.Char.patchStatus, timeout: 15)
            appendHandoffLog("post-auth patchStatus read \(raw.count)B raw=\(Self.hex(raw))")
            do {
                let frame = try DataFrame.parse(raw)
                let packet = try DataPlaneDecoder(crypto: crypto).decrypt(frame: frame, channel: .patchStatus)
                let fallback = packet.usedPreferredKind ? "" : " fallback"
                recordDecodedPacket(packet, channelName: "patchStatus", receivedAt: Date())
                appendHandoffLog(
                    "post-auth patchStatus read decrypt " +
                    "seq=0x\(String(format: "%04x", frame.sequenceNumber)) " +
                    "kind=\(packet.kind.rawValue)\(fallback) " +
                    "pt(\(packet.plaintext.count)B)=\(Self.hex(packet.plaintext))" +
                    Self.decodedDataPlaneSummary(packet)
                )
            } catch {
                appendHandoffLog("post-auth patchStatus read decrypt pending: \(String(describing: error))")
            }
        } catch {
            appendHandoffLog("post-auth patchStatus read failed: \(String(describing: error))")
        }
    }

    nonisolated private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func dataPlaneChannelName(_ channel: DataPlaneChannel) -> String {
        switch channel {
        case .patchControl: return "patchControl"
        case .patchStatus: return "patchStatus"
        case .glucoseData: return "glucoseData"
        case .historicData: return "historicData"
        case .eventLog: return "eventLog"
        case .clinicalData: return "clinicalData"
        case .factoryData: return "factoryData"
        }
    }

    nonisolated private static func connectionEventName(_ event: CBConnectionEvent) -> String {
        switch event {
        case .peerConnected:
            return "peerConnected"
        case .peerDisconnected:
            return "peerDisconnected"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated private static func centralStateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated private static func decodedDataPlaneSummary(_ packet: DataPlaneDecodedPacket) -> String {
        switch packet.payload {
        case .historicalReadingPage(let page):
            let values = page.values.map(String.init).joined(separator: ",")
            return " histLC=\(page.startLifeCount)..\(page.endLifeCount) values=[\(values)]"
        case .realtimeGlucose(let reading):
            let rate = reading.rateOfChangeMgDLPerMinute.map { String(format: "%.2f", $0) } ?? "nil"
            let current = reading.currentGlucoseMgDL.map(String.init) ?? "invalid"
            return " glucoseLC=\(reading.lifeCount) current=\(current) " +
                "rate=\(rate) trend=\(reading.trend) histLC=\(reading.historicalLifeCount) " +
                "hist=\(reading.historicalReading) tempRaw=\(reading.temperature) " +
                "statusBits=\(reading.statusBits) fastWords=\(reading.fastDataWordsLE)"
        case .patchStatus(let status):
            let lifecycle = status.lifecycle()
            return " patchState=\(status.patchState) currentLC=\(status.currentLifeCount) " +
                "phase=\(lifecycle.phase.rawValue) warmupLeft=\(lifecycle.remainingWarmupMinutes) " +
                "events=\(status.totalEvents) stackDisconnect=\(status.stackDisconnectReason) " +
                "appDisconnect=\(status.appDisconnectReason)"
        case .clinicalReadingRecord(let record):
            let current = record.currentGlucoseMgDL.map(String.init) ?? "invalid"
            let historic = record.historicGlucoseMgDL.map(String.init) ?? "invalid"
            let historicLifeCount = record.historicLifeCountEstimate.map(String.init) ?? "unknown"
            return " clinicalLC=\(record.lifeCount) current=\(current) " +
                "historicLC=\(historicLifeCount) historic=\(historic)"
        case .raw:
            if packet.channel == .glucoseData {
                return " glucoseWordsLE=\(littleEndianWordSummary(packet.plaintext))"
            }
            if packet.channel == .patchStatus {
                return " patchStatusWordsLE=\(littleEndianWordSummary(packet.plaintext))"
            }
            return ""
        }
    }

    nonisolated private static func littleEndianWordSummary(_ data: Data) -> String {
        var words: [String] = []
        var index = data.startIndex
        while data.distance(from: data.startIndex, to: index) + 1 < data.count {
            let next = data.index(after: index)
            let value = UInt16(data[index]) | (UInt16(data[next]) << 8)
            words.append(String(value))
            index = data.index(index, offsetBy: 2)
        }
        if data.count % 2 == 1, let last = data.last {
            words.append(String(format: "tail:%02x", last))
        }
        return "[" + words.joined(separator: ",") + "]"
    }

    nonisolated private static func phase6NoncePrefix(fromNonce nonce: Data) -> UInt16? {
        guard nonce.count >= 2 else { return nil }
        return UInt16(nonce[nonce.startIndex]) | (UInt16(nonce[nonce.startIndex + 1]) << 8)
    }

    nonisolated private static func historyBackfillStart(
        phase6NoncePrefix: UInt16?,
        savedLastLifeCount: UInt16?
    ) -> UInt16 {
        if let savedLastLifeCount {
            let overlap: UInt16 = 10
            return savedLastLifeCount > overlap ? savedLastLifeCount - overlap : 0
        }
        guard let phase6NoncePrefix else {
            return 5
        }
        let lookback: UInt16 = 180
        return phase6NoncePrefix > lookback ? phase6NoncePrefix - lookback : 0
    }

    nonisolated private static func normalizedBLEAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .filter { $0.isHexDigit }
            .uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated private static func manualBLEAddress(from raw: String) throws -> String {
        let bytes = try manualHexData(raw, expectedByteCount: 6, field: "Adresa BLE")
        return bytes
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    nonisolated private static func manualHexData(
        _ raw: String,
        expectedByteCount: Int,
        field: String
    ) throws -> Data {
        let compact = raw
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard compact.count == expectedByteCount * 2,
              compact.allSatisfy(\.isHexDigit) else {
            throw ManualSensorImportError.invalidHex(
                field: field,
                expectedByteCount: expectedByteCount
            )
        }

        var data = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw ManualSensorImportError.invalidHex(
                    field: field,
                    expectedByteCount: expectedByteCount
                )
            }
            data.append(byte)
            index = next
        }
        return data
    }

    nonisolated private static func secureRandomData(count: Int) throws -> Data {
        guard count >= 0 else {
            throw NFCActivationHandoffError.randomFailed(errSecParam)
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, rawBuffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw NFCActivationHandoffError.randomFailed(status)
        }
        return Data(bytes)
    }

    nonisolated private static func fixedEntropySource(_ entropy: Data, requestedCount: Int) throws -> Data {
        guard requestedCount == entropy.count else {
            throw NFCActivationHandoffError.fixedEntropySizeMismatch(
                expected: requestedCount,
                actual: entropy.count
            )
        }
        return entropy
    }

    private func loadPhoneCert() throws -> (cert: PhoneCert, label: String) {
        guard useCapturedUserCert else {
            return (try PhoneCert.bundledFirstPair(), "phone_cert_firstpair")
        }
        guard let url = Bundle.main.url(forResource: "phone_cert_162b", withExtension: "bin") else {
            throw NFCActivationHandoffError.bundledResourceMissing("phone_cert_162b")
        }
        return (try PhoneCert(raw: try Data(contentsOf: url)), "phone_cert_162b")
    }

    private func appendHandoffLog(_ msg: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let line = "[\(ts)] \(msg)"
        persistHandoffLogLine(line)
        print("[LibreCR:NFC] \(line)")
    }

    private func makeHandoffEventLogger() -> @Sendable (String) -> Void {
        { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendHandoffLog(message)
            }
        }
    }

    private func handoffLogURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibreCR-nfc-handoff-log.txt")
    }

    private func persistHandoffLogLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        let url = handoffLogURL()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func receiverIDOverride(from arguments: [String]) -> (id: UInt32, source: String)? {
        if let raw = argumentValue(after: "--nfc-receiver-id", in: arguments),
           let id = parseUInt32(raw) {
            return (id, "--nfc-receiver-id \(raw)")
        }
        if let raw = argumentValue(after: "--nfc-receiver-le-hex", in: arguments),
           let id = Libre3ReceiverID.parseLittleEndianHex(raw) {
            return (id, "--nfc-receiver-le-hex \(raw)")
        }
        return nil
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    private static func parseUInt32(_ raw: String) -> UInt32? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed, radix: 10) ?? UInt32(trimmed, radix: 16)
    }

    private static func missingPhase5RawKeyMessage(for state: Libre3SensorState) -> String {
        let identity = state.bleAddress ?? state.serialNumber ?? "senzorul salvat"
        return "Starea pentru \(identity) nu conține încă cheia Phase 5. " +
            "Apropie senzorul de telefon și apasă „Pair saved” (sau „Run pairing candidate”): " +
            "se face un pairing prin NFC o singură dată, care obține și salvează cheia. " +
            "După aceea reconectarea e rapidă, fără NFC. " +
            "Reconnect-ul automat nu pornește singur derivarea lentă, fiindcă produce timeout pe un senzor deja împerecheat."
    }

}

private enum NFCActivationHandoffError: Error, CustomStringConvertible, LocalizedError {
    case bundledResourceMissing(String)
    case fixedEntropySizeMismatch(expected: Int, actual: Int)
    case missingPhase5RawKey
    case randomFailed(OSStatus)

    var description: String {
        switch self {
        case .bundledResourceMissing(let name):
            return "Bundled resource missing: \(name)"
        case .fixedEntropySizeMismatch(let expected, let actual):
            return "Fixed entropy size mismatch: expected \(expected), got \(actual)"
        case .missingPhase5RawKey:
            return "Missing Phase 5 raw key for saved-state reconnect"
        case .randomFailed(let status):
            return "Secure random failed: \(status)"
        }
    }

    var errorDescription: String? {
        description
    }
}

private actor FirstPairPostAuthCounter {
    private var notifyCount = 0
    private var streamEnded = false
    private var lastReceivedAt: Date?

    func mark(receivedAt: Date) -> Int {
        notifyCount += 1
        lastReceivedAt = receivedAt
        return notifyCount
    }

    func value() -> Int {
        notifyCount
    }

    func lastNotifyAt() -> Date? {
        lastReceivedAt
    }

    func markStreamEnded() {
        streamEnded = true
    }

    func isStreamEnded() -> Bool {
        streamEnded
    }
}
