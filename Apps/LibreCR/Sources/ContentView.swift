import SwiftUI
import Charts
import LibreCRKit
import CoreBluetooth
import UIKit

struct ContentView: View {
    @StateObject private var nfcModel = NFCActivationViewModel()
    @StateObject private var alarmManager = GlucoseAlarmManager.shared
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--show-manual-sensor-import")
        ? RootTab.nfc
        : RootTab.dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(model: nfcModel, store: nfcModel.readingStore)
                .tabItem { Label("Acasă", systemImage: "chart.xyaxis.line") }
                .tag(RootTab.dashboard)
            GlucoseHistoryView(store: nfcModel.readingStore)
                .tabItem { Label("Istoric", systemImage: "clock.arrow.circlepath") }
                .tag(RootTab.history)
            NFCActivationView(model: nfcModel)
                .tabItem { Label("Senzor", systemImage: "wave.3.right") }
                .tag(RootTab.nfc)
            GlucoseAlarmSettingsView(manager: alarmManager)
                .tabItem { Label("Alarme", systemImage: "bell.badge.fill") }
                .tag(RootTab.alarms)
            ScanDebugView()
                .tabItem { Label("Debug", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(RootTab.scan)
        }
        .tint(AppPalette.accent)
        .task {
            nfcModel.runLaunchAutomationIfRequested()
        }
        .fullScreenCover(item: $alarmManager.activeAlarm) { alarm in
            GlucoseAlarmFullScreenView(alarm: alarm, manager: alarmManager)
        }
    }

    private enum RootTab: Hashable {
        case dashboard
        case history
        case nfc
        case alarms
        case scan
    }
}

struct DashboardView: View {
    @ObservedObject var model: NFCActivationViewModel
    @ObservedObject var store: GlucoseReadingStore
    @State private var chartRange = GlucoseChartRange.sixHours

    private var latest: StoredGlucoseReading? {
        store.latest
    }

    private var chartReadings: [StoredGlucoseReading] {
        store.readings(since: Date().addingTimeInterval(-chartRange.duration))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dashboardHeader
                    currentGlucoseCard
                    chartCard
                    summaryCards
                    storageCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .navigationTitle("LibreCR")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Monitorizare glucoză")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("Valorile tale, într-un singur loc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionBadge(isConnected: model.hasActiveConnection)
        }
    }

    private var currentGlucoseCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Glucoză curentă", systemImage: "drop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                    Spacer()
                    Text(latest?.receivedAt.relativeDisplay ?? "Fără citiri")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text(latest.map { "\($0.glucoseMgDL)" } ?? "--")
                        .font(.system(size: 70, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 5) {
                        Text("mg/dL")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if let latest {
                            Label(latest.trendPresentation.label, systemImage: latest.trendPresentation.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(latest.trendPresentation.color)
                        } else {
                            Text("Aștept o valoare")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    HeroMetric(
                        title: "Delta",
                        value: store.latestDelta.map { $0.signedMgDLDisplay } ?? "--",
                        systemImage: "plus.forwardslash.minus"
                    )
                    HeroMetric(
                        title: "Ritm",
                        value: latest?.rateOfChangeMgDLPerMinute.map { String(format: "%+.1f/min", $0) } ?? "--",
                        systemImage: "speedometer"
                    )
                    HeroMetric(
                        title: "Status",
                        value: latest.map { $0.rangeStatus.title } ?? "--",
                        systemImage: "checkmark.circle"
                    )
                }
            }
        }
    }

    private var chartCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Evoluție")
                            .font(.headline)
                        Text("Interval țintă 70–180 mg/dL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Interval grafic", selection: $chartRange) {
                        ForEach(GlucoseChartRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppPalette.accent)
                }

                if chartReadings.isEmpty {
                    ChartEmptyState()
                        .frame(height: 205)
                } else {
                    GlucoseChart(readings: chartReadings, range: chartRange)
                        .frame(height: 205)
                }
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            CompactMetricCard(
                title: "GMI estimat",
                value: store.gmi(days: 14).map { String(format: "%.1f%%", $0) } ?? "--",
                detail: "Ultimele 14 zile",
                tint: AppPalette.purple,
                systemImage: "percent"
            )
            CompactMetricCard(
                title: "Medie",
                value: store.averageGlucose(days: 14).map { "\(Int($0.rounded()))" } ?? "--",
                detail: "mg/dL · 14 zile",
                tint: AppPalette.orange,
                systemImage: "chart.bar.fill"
            )
        }
    }

    private var storageCard: some View {
        DashboardCard {
            HStack(spacing: 13) {
                Image(systemName: "internaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(AppPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stocare locală activă")
                        .font(.subheadline.weight(.semibold))
                    Text("\(store.readings.count) valori salvate pe acest dispozitiv")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppPalette.green)
            }
        }
    }
}

struct GlucoseHistoryView: View {
    @ObservedObject var store: GlucoseReadingStore
    @State private var selectedPeriod = GlucoseMetricPeriod.fourteenDays
    @State private var showingClearConfirmation = false

    private var filteredReadings: [StoredGlucoseReading] {
        store.readings(since: Date().addingTimeInterval(-selectedPeriod.duration))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    periodPicker
                    gmiCard
                    storedValuesSection
                }
                .padding(18)
                .padding(.bottom, 20)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .navigationTitle("Istoric")
            .toolbar {
                if !store.readings.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Șterge", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .alert("Ștergi istoricul local?", isPresented: $showingClearConfirmation) {
                Button("Anulează", role: .cancel) {}
                Button("Șterge", role: .destructive) {
                    store.removeAll()
                }
            } message: {
                Text("Valorile salvate pe acest dispozitiv vor fi eliminate definitiv.")
            }
        }
    }

    private var periodPicker: some View {
        Picker("Perioadă", selection: $selectedPeriod) {
            ForEach(GlucoseMetricPeriod.allCases) { period in
                Text(period.shortTitle).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }

    private var gmiCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Glucose Management Indicator")
                            .font(.headline)
                        Text("Estimare calculată din valorile CGM stocate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.title2)
                        .foregroundStyle(AppPalette.purple)
                }

                Text(store.gmi(days: selectedPeriod.days).map { String(format: "%.1f%%", $0) } ?? "--")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .contentTransition(.numericText())

                HStack(spacing: 10) {
                    GMIStat(
                        title: "Medie",
                        value: store.averageGlucose(days: selectedPeriod.days).map { "\(Int($0.rounded())) mg/dL" } ?? "--"
                    )
                    GMIStat(
                        title: "În interval",
                        value: store.timeInRange(days: selectedPeriod.days).map { String(format: "%.0f%%", $0) } ?? "--"
                    )
                    GMIStat(title: "Citiri", value: "\(filteredReadings.count)")
                }

                Text("GMI este o estimare orientativă și nu înlocuiește analiza HbA1c de laborator.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storedValuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Valori stocate")
                    .font(.headline)
                Spacer()
                Text("\(store.readings.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredReadings.isEmpty {
                DashboardCard {
                    Text("Citirile primite de la senzor vor apărea aici și vor fi păstrate local.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(filteredReadings.suffix(80).reversed()) { reading in
                        StoredReadingRow(reading: reading)
                    }
                }
            }
        }
    }
}

struct GlucoseChart: View {
    let readings: [StoredGlucoseReading]
    let range: GlucoseChartRange

    private var yDomain: ClosedRange<Double> {
        let values = readings.map { Double($0.glucoseMgDL) }
        let minimum = max(40, (values.min() ?? 70) - 18)
        let maximum = min(320, max(200, (values.max() ?? 180) + 18))
        return minimum...maximum
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Prag superior", 180))
                .foregroundStyle(AppPalette.orange.opacity(0.42))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 5]))
            RuleMark(y: .value("Prag inferior", 70))
                .foregroundStyle(AppPalette.orange.opacity(0.42))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 5]))

            ForEach(readings) { reading in
                AreaMark(
                    x: .value("Oră", reading.receivedAt),
                    y: .value("Glucoză", reading.glucoseMgDL)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppPalette.accent.opacity(0.22), AppPalette.accent.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Oră", reading.receivedAt),
                    y: .value("Glucoză", reading.glucoseMgDL)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .foregroundStyle(AppPalette.accent)
            }

            if let latest = readings.last {
                PointMark(
                    x: .value("Oră", latest.receivedAt),
                    y: .value("Glucoză", latest.glucoseMgDL)
                )
                .symbolSize(72)
                .foregroundStyle(AppPalette.accent)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: range.axisStrideHours)) { _ in
                AxisGridLine().foregroundStyle(AppPalette.grid)
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(AppPalette.grid)
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
    }
}

struct StoredReadingRow: View {
    let reading: StoredGlucoseReading

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reading.rangeStatus.symbol)
                .foregroundStyle(reading.rangeStatus.color)
                .frame(width: 34, height: 34)
                .background(reading.rangeStatus.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(reading.glucoseMgDL)")
                        .font(.system(.headline, design: .rounded))
                    Text("mg/dL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(reading.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Image(systemName: reading.trendPresentation.symbol)
                    .foregroundStyle(reading.trendPresentation.color)
                Text(reading.rateOfChangeMgDLPerMinute.map { String(format: "%+.1f/min", $0) } ?? "--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor
final class GlucoseReadingStore: ObservableObject {
    @Published private(set) var readings: [StoredGlucoseReading] = []

    private let storageURL: URL?
    private let retentionDuration: TimeInterval = 90 * 24 * 60 * 60

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? GlucoseReadingStore.defaultStorageURL()
        load()
    }

    var latest: StoredGlucoseReading? {
        readings.last
    }

    var latestDelta: Int? {
        guard readings.count >= 2 else { return nil }
        let current = readings[readings.count - 1]
        let previous = readings[readings.count - 2]
        guard current.sensorSerialNumber == previous.sensorSerialNumber,
              current.receivedAt.timeIntervalSince(previous.receivedAt) <= 10 * 60 else {
            return nil
        }
        return Int(current.glucoseMgDL) - Int(previous.glucoseMgDL)
    }

    func record(_ display: GlucoseDisplay, sensorSerialNumber: String?) {
        guard let reading = StoredGlucoseReading(display: display, sensorSerialNumber: sensorSerialNumber) else {
            return
        }
        if let existingIndex = readings.firstIndex(where: { $0.id == reading.id }) {
            readings[existingIndex] = reading
        } else {
            readings.append(reading)
        }
        normalize()
        persist()
        if let latest {
            GlucoseLiveActivityManager.shared.sync(latest: latest, deltaMgDL: latestDelta)
        }
        GlucoseAlarmManager.shared.evaluate(reading)
    }

    func readings(since date: Date) -> [StoredGlucoseReading] {
        readings.filter { $0.receivedAt >= date }
    }

    func averageGlucose(days: Int) -> Double? {
        let values = metricReadings(days: days).map { Double($0.glucoseMgDL) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func gmi(days: Int) -> Double? {
        guard let average = averageGlucose(days: days) else { return nil }
        return 3.31 + 0.02392 * average
    }

    func timeInRange(days: Int) -> Double? {
        let values = metricReadings(days: days)
        guard !values.isEmpty else { return nil }
        let inRange = values.filter { (70...180).contains(Int($0.glucoseMgDL)) }.count
        return Double(inRange) / Double(values.count) * 100
    }

    func removeAll() {
        readings.removeAll()
        persist()
        GlucoseLiveActivityManager.shared.end()
    }

    private func metricReadings(days: Int) -> [StoredGlucoseReading] {
        readings(since: Date().addingTimeInterval(-Double(days) * 24 * 60 * 60))
    }

    private func load() {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder.glucoseStore.decode([StoredGlucoseReading].self, from: data) else {
            return
        }
        readings = decoded
        normalize()
    }

    private func normalize() {
        let cutoff = Date().addingTimeInterval(-retentionDuration)
        var uniqueByID: [String: StoredGlucoseReading] = [:]
        for reading in readings where reading.receivedAt >= cutoff {
            uniqueByID[reading.id] = reading
        }
        readings = uniqueByID.values.sorted { $0.receivedAt < $1.receivedAt }
    }

    private func persist() {
        guard let storageURL,
              let data = try? JSONEncoder.glucoseStore.encode(readings) else {
            return
        }
        try? data.write(to: storageURL, options: .atomic)
    }

    private static func defaultStorageURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = root.appendingPathComponent("LibreCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("GlucoseReadings.json")
    }
}

struct StoredGlucoseReading: Codable, Identifiable, Equatable {
    let id: String
    let receivedAt: Date
    let sensorSerialNumber: String?
    let lifeCount: UInt16
    let glucoseMgDL: UInt16
    let rateOfChangeMgDLPerMinute: Float?
    let trend: UInt8

    init?(display: GlucoseDisplay, sensorSerialNumber: String?) {
        guard let glucoseMgDL = display.currentGlucoseMgDL else { return nil }
        self.id = "\(sensorSerialNumber ?? "unknown")-\(display.lifeCount)"
        self.receivedAt = display.receivedAt
        self.sensorSerialNumber = sensorSerialNumber
        self.lifeCount = display.lifeCount
        self.glucoseMgDL = glucoseMgDL
        self.rateOfChangeMgDLPerMinute = display.rateOfChangeMgDLPerMinute
        self.trend = display.trend
    }

    var trendPresentation: GlucoseTrendPresentation {
        GlucoseTrendPresentation(rawValue: trend)
    }

    var rangeStatus: GlucoseRangeStatus {
        GlucoseRangeStatus(value: glucoseMgDL)
    }
}

struct GlucoseTrendPresentation {
    let symbol: String
    let label: String
    let color: Color

    init(rawValue: UInt8) {
        switch rawValue {
        case 1:
            self.init(symbol: "arrow.down", label: "Scade rapid", color: AppPalette.red)
        case 2:
            self.init(symbol: "arrow.down.right", label: "În scădere", color: AppPalette.orange)
        case 3:
            self.init(symbol: "arrow.right", label: "Stabil", color: AppPalette.green)
        case 4:
            self.init(symbol: "arrow.up.right", label: "În creștere", color: AppPalette.orange)
        case 5:
            self.init(symbol: "arrow.up", label: "Crește rapid", color: AppPalette.red)
        default:
            self.init(symbol: "questionmark", label: "Trend indisponibil", color: .secondary)
        }
    }

    private init(symbol: String, label: String, color: Color) {
        self.symbol = symbol
        self.label = label
        self.color = color
    }
}

enum GlucoseRangeStatus {
    case low
    case inRange
    case high

    init(value: UInt16) {
        switch value {
        case ..<70:
            self = .low
        case 181...:
            self = .high
        default:
            self = .inRange
        }
    }

    var title: String {
        switch self {
        case .low: return "Scăzut"
        case .inRange: return "În interval"
        case .high: return "Ridicat"
        }
    }

    var symbol: String {
        switch self {
        case .low: return "arrow.down"
        case .inRange: return "checkmark"
        case .high: return "arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .low: return AppPalette.red
        case .inRange: return AppPalette.green
        case .high: return AppPalette.orange
        }
    }
}

enum GlucoseChartRange: String, CaseIterable, Identifiable {
    case threeHours
    case sixHours
    case twelveHours
    case twentyFourHours

    var id: Self { self }

    var title: String {
        switch self {
        case .threeHours: return "3h"
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .twentyFourHours: return "24h"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .threeHours: return 3 * 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .twelveHours: return 12 * 60 * 60
        case .twentyFourHours: return 24 * 60 * 60
        }
    }

    var axisStrideHours: Int {
        switch self {
        case .threeHours: return 1
        case .sixHours: return 2
        case .twelveHours: return 3
        case .twentyFourHours: return 6
        }
    }
}

enum GlucoseMetricPeriod: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Self { self }
    var days: Int { rawValue }
    var duration: TimeInterval { Double(days) * 24 * 60 * 60 }
    var shortTitle: String { "\(days)z" }
}

struct DashboardCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: AppPalette.shadow, radius: 12, y: 5)
    }
}

struct ConnectionBadge: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? AppPalette.green : AppPalette.orange)
                .frame(width: 7, height: 7)
            Text(isConnected ? "Conectat" : "Offline")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AppPalette.card, in: Capsule())
    }
}

struct HeroMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct CompactMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let systemImage: String

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GMIStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(AppPalette.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChartEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundStyle(AppPalette.accent)
            Text("Graficul se va actualiza automat")
                .font(.subheadline.weight(.semibold))
            Text("Conectează senzorul pentru a primi valori.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14))
    }
}

private enum AppPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(red: 0.04, green: 0.55, blue: 0.59)
    static let green = Color(red: 0.13, green: 0.64, blue: 0.43)
    static let orange = Color(red: 0.94, green: 0.55, blue: 0.20)
    static let purple = Color(red: 0.46, green: 0.36, blue: 0.78)
    static let red = Color(red: 0.86, green: 0.29, blue: 0.32)
    static let ink = Color.primary
    static let grid = Color(uiColor: .separator)
    static let shadow = Color.black.opacity(0.08)
}

private extension JSONEncoder {
    static var glucoseStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var glucoseStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Date {
    var relativeDisplay: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

private extension Int {
    var signedMgDLDisplay: String {
        String(format: "%+d mg/dL", self)
    }
}

/// Original scan-only debug view (kept for BLE diagnostics).
struct ScanDebugView: View {
    @StateObject private var model = ScanViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                discoveredList
                Spacer()
                controls
            }
            .padding()
            .navigationTitle("Scan")
        }
    }

    private var statusLine: some View {
        HStack {
            Circle()
                .fill(model.isReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var discoveredList: some View {
        Group {
            if model.discovered.isEmpty {
                Text(model.scanning ? "Scanning…" : "No sensors yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(model.discovered, id: \.id) { d in
                    Button {
                        model.connect(d)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name ?? "Unknown").font(.body)
                            Text("\(d.id.uuidString.prefix(8))… · RSSI \(d.rssi)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !d.advertisedServices.isEmpty {
                                Text("svc: " + d.advertisedServices.map { $0.uuidString }.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Scan all (debug)", isOn: $model.scanAll)
                .font(.caption)
                .disabled(model.scanning)
            HStack {
                Button(model.scanning ? "Stop scan" : "Scan for sensor") {
                    model.toggleScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady && !model.scanning)
                Spacer()
                Text("LibreCRKit \(LibreCRKit.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var statusText: String = "Initializing…"
    @Published var isReady = false
    @Published var scanning = false
    @Published var scanAll = false
    @Published var discovered: [DiscoveredSensor] = []

    private let scanner = SensorScanner()
    private var scanTask: Task<Void, Never>?

    init() {
        Task { await self.bootstrap() }
    }

    func bootstrap() async {
        do {
            try await scanner.waitUntilReady()
            isReady = true
            statusText = "Bluetooth ready"
        } catch {
            statusText = "BLE error: \(error)"
        }
    }

    func toggleScan() {
        if scanning {
            scanner.stopScan()
            scanTask?.cancel()
            scanning = false
            statusText = "Scan stopped"
        } else {
            discovered.removeAll()
            scanning = true
            statusText = scanAll ? "Scanning for ALL BLE devices…" : "Scanning for Libre 3 sensor…"
            let filter: [CBUUID]? = scanAll ? nil : [LibreSensorGATT.serviceUUID]
            scanTask = Task { [weak self] in
                guard let self else { return }
                let stream = self.scanner.startScan(filter: filter)
                for await found in stream {
                    if !self.discovered.contains(where: { $0.id == found.id }) {
                        self.discovered.append(found)
                    }
                }
            }
        }
    }

    func connect(_ d: DiscoveredSensor) {
        scanner.stopScan()
        scanning = false
        statusText = "Connecting to \(d.name ?? String(d.id.uuidString.prefix(8)))…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.scanner.connect(d.peripheral)
                self.statusText = "Connected. \(session.peripheral.services?.count ?? 0) services discovered."
            } catch {
                self.statusText = "Connect failed: \(error)"
            }
        }
    }
}

#Preview {
    ContentView()
}
