import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum GlucoseAlarmKind: String {
    case low
    case high

    var title: String {
        switch self {
        case .low: return "Glucoză scăzută"
        case .high: return "Glucoză ridicată"
        }
    }

    var notificationTitle: String {
        switch self {
        case .low: return "Alarmă LOW"
        case .high: return "Alarmă HIGH"
        }
    }

    var detail: String {
        switch self {
        case .low: return "Valoarea este sub pragul configurat."
        case .high: return "Valoarea este peste pragul configurat."
        }
    }

    var symbol: String {
        switch self {
        case .low: return "arrow.down.circle.fill"
        case .high: return "arrow.up.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .low: return GlucoseAlarmPalette.low
        case .high: return GlucoseAlarmPalette.high
        }
    }
}

struct GlucoseAlarm: Identifiable {
    let id = UUID()
    let kind: GlucoseAlarmKind
    let glucoseMgDL: UInt16
    let occurredAt: Date
}

@MainActor
final class GlucoseAlarmManager: NSObject, ObservableObject {
    static let shared = GlucoseAlarmManager()

    @Published var activeAlarm: GlucoseAlarm?
    @Published private(set) var authorizationStatus = UNAuthorizationStatus.notDetermined
    @Published private(set) var snoozedUntil: Date?
    @Published var lowEnabled: Bool {
        didSet { defaults.set(lowEnabled, forKey: DefaultsKey.lowEnabled) }
    }
    @Published var highEnabled: Bool {
        didSet { defaults.set(highEnabled, forKey: DefaultsKey.highEnabled) }
    }
    @Published var lowThreshold: Int {
        didSet { defaults.set(lowThreshold, forKey: DefaultsKey.lowThreshold) }
    }
    @Published var highThreshold: Int {
        didSet { defaults.set(highThreshold, forKey: DefaultsKey.highThreshold) }
    }
    @Published var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: DefaultsKey.snoozeMinutes) }
    }
    @Published var fullScreenWhenPossible: Bool {
        didSet { defaults.set(fullScreenWhenPossible, forKey: DefaultsKey.fullScreenWhenPossible) }
    }

    private enum DefaultsKey {
        static let lowEnabled = "LibreCRAlarmLowEnabled"
        static let highEnabled = "LibreCRAlarmHighEnabled"
        static let lowThreshold = "LibreCRAlarmLowThreshold"
        static let highThreshold = "LibreCRAlarmHighThreshold"
        static let snoozeMinutes = "LibreCRAlarmSnoozeMinutes"
        static let fullScreenWhenPossible = "LibreCRAlarmFullScreenWhenPossible"
        static let snoozedUntil = "LibreCRAlarmSnoozedUntil"
    }

    private static let categoryIdentifier = "org.librecr.glucose-alarm"
    private static let snoozeActionIdentifier = "org.librecr.glucose-alarm.snooze"
    private static let snoozeRequestIdentifier = "org.librecr.glucose-alarm.snoozed-reminder"
    private static let kindUserInfoKey = "glucoseAlarmKind"
    private static let valueUserInfoKey = "glucoseMgDL"
    private static let occurredAtUserInfoKey = "occurredAt"

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var lastTriggeredKind: GlucoseAlarmKind?
    private var lastTriggeredAt: Date?

    private override init() {
        let defaults = UserDefaults.standard
        lowEnabled = defaults.object(forKey: DefaultsKey.lowEnabled) as? Bool ?? true
        highEnabled = defaults.object(forKey: DefaultsKey.highEnabled) as? Bool ?? true
        lowThreshold = defaults.object(forKey: DefaultsKey.lowThreshold) as? Int ?? 70
        highThreshold = defaults.object(forKey: DefaultsKey.highThreshold) as? Int ?? 180
        snoozeMinutes = defaults.object(forKey: DefaultsKey.snoozeMinutes) as? Int ?? 15
        fullScreenWhenPossible = defaults.object(forKey: DefaultsKey.fullScreenWhenPossible) as? Bool ?? true
        let persistedSnooze = defaults.object(forKey: DefaultsKey.snoozedUntil) as? Date
        snoozedUntil = persistedSnooze.flatMap { $0 > Date() ? $0 : nil }
        super.init()
    }

    func activate() {
        center.delegate = self
        registerCategory()
        refreshAuthorizationStatus(requestIfNeeded: true)
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshAuthorizationStatus()
            }
        }
    }

    func refreshAuthorizationStatus(requestIfNeeded: Bool = false) {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = settings.authorizationStatus
                if requestIfNeeded, settings.authorizationStatus == .notDetermined {
                    self.requestAuthorization()
                }
            }
        }
    }

    func evaluate(_ reading: StoredGlucoseReading) {
        guard let kind = alarmKind(for: reading) else {
            resolveActiveAlarm()
            return
        }

        let now = Date()
        guard snoozedUntil.map({ $0 <= now }) ?? true else {
            return
        }

        let repeatInterval = TimeInterval(snoozeMinutes * 60)
        let shouldTrigger = lastTriggeredKind != kind ||
            lastTriggeredAt.map { now.timeIntervalSince($0) >= repeatInterval } ?? true
        guard shouldTrigger else {
            return
        }

        let alarm = GlucoseAlarm(kind: kind, glucoseMgDL: reading.glucoseMgDL, occurredAt: reading.receivedAt)
        lastTriggeredKind = kind
        lastTriggeredAt = now
        if fullScreenWhenPossible {
            activeAlarm = alarm
        }
        scheduleNotification(for: alarm)
    }

    func preview(_ kind: GlucoseAlarmKind) {
        let value = kind == .low ? max(39, lowThreshold - 8) : min(501, highThreshold + 22)
        activeAlarm = GlucoseAlarm(kind: kind, glucoseMgDL: UInt16(value), occurredAt: Date())
    }

    func snooze(_ alarm: GlucoseAlarm? = nil) {
        let alarm = alarm ?? activeAlarm
        activeAlarm = nil
        guard let alarm else { return }

        let date = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        snoozedUntil = date
        defaults.set(date, forKey: DefaultsKey.snoozedUntil)
        lastTriggeredKind = alarm.kind
        lastTriggeredAt = date
        scheduleNotification(for: alarm, after: TimeInterval(snoozeMinutes * 60), isSnoozedReminder: true)
    }

    func dismissActiveAlarm() {
        activeAlarm = nil
    }

    var authorizationDescription: String {
        switch authorizationStatus {
        case .authorized: return "Notificările sunt active."
        case .provisional: return "Notificările sunt livrate silențios."
        case .ephemeral: return "Notificările sunt permise temporar."
        case .denied: return "Notificările sunt blocate din configurările iOS."
        case .notDetermined: return "Permisiunea pentru notificări nu a fost încă acordată."
        @unknown default: return "Starea notificărilor nu este disponibilă."
        }
    }

    var shouldOfferAuthorizationButton: Bool {
        authorizationStatus == .notDetermined
    }

    var shouldOfferSettingsButton: Bool {
        authorizationStatus == .denied
    }

    private func alarmKind(for reading: StoredGlucoseReading) -> GlucoseAlarmKind? {
        if lowEnabled, reading.glucoseMgDL < lowThreshold {
            return .low
        }
        if highEnabled, reading.glucoseMgDL > highThreshold {
            return .high
        }
        return nil
    }

    private func resolveActiveAlarm() {
        activeAlarm = nil
        snoozedUntil = nil
        defaults.removeObject(forKey: DefaultsKey.snoozedUntil)
        lastTriggeredKind = nil
        lastTriggeredAt = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.snoozeRequestIdentifier])
    }

    private func registerCategory() {
        let snoozeAction = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "Amână",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func scheduleNotification(
        for alarm: GlucoseAlarm,
        after delay: TimeInterval? = nil,
        isSnoozedReminder: Bool = false
    ) {
        if isSnoozedReminder {
            center.removePendingNotificationRequests(withIdentifiers: [Self.snoozeRequestIdentifier])
        }

        let content = UNMutableNotificationContent()
        content.title = isSnoozedReminder ? "Alarmă amânată" : alarm.kind.notificationTitle
        content.body = "\(alarm.glucoseMgDL) mg/dL. \(alarm.kind.detail)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = alarm.kind.rawValue
        content.userInfo = [
            Self.kindUserInfoKey: alarm.kind.rawValue,
            Self.valueUserInfoKey: Int(alarm.glucoseMgDL),
            Self.occurredAtUserInfoKey: alarm.occurredAt.timeIntervalSince1970,
        ]

        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let identifier = isSnoozedReminder
            ? Self.snoozeRequestIdentifier
            : "org.librecr.glucose-alarm.\(alarm.kind.rawValue).\(UUID().uuidString)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func alarm(from userInfo: [AnyHashable: Any]) -> GlucoseAlarm? {
        guard let rawKind = userInfo[Self.kindUserInfoKey] as? String,
              let kind = GlucoseAlarmKind(rawValue: rawKind),
              let value = userInfo[Self.valueUserInfoKey] as? Int else {
            return nil
        }
        let occurredAt = (userInfo[Self.occurredAtUserInfoKey] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            ?? Date()
        return GlucoseAlarm(kind: kind, glucoseMgDL: UInt16(clamping: value), occurredAt: occurredAt)
    }
}

extension GlucoseAlarmManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            defer { completionHandler() }
            guard let alarm = self.alarm(from: response.notification.request.content.userInfo) else {
                return
            }
            if response.actionIdentifier == Self.snoozeActionIdentifier {
                self.snooze(alarm)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.activeAlarm = alarm
            }
        }
    }
}

struct GlucoseAlarmSettingsView: View {
    @ObservedObject var manager: GlucoseAlarmManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Notificări") {
                    Label(manager.authorizationDescription, systemImage: notificationSymbol)
                        .foregroundStyle(notificationColor)
                    if manager.shouldOfferAuthorizationButton {
                        Button("Permite notificările") {
                            manager.requestAuthorization()
                        }
                    }
                    if manager.shouldOfferSettingsButton {
                        Button("Deschide configurările iOS") {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }

                Section("Prag LOW") {
                    Toggle("Alarmă LOW activă", isOn: $manager.lowEnabled)
                    Stepper("Sub \(manager.lowThreshold) mg/dL", value: $manager.lowThreshold, in: 50...100, step: 5)
                }

                Section("Prag HIGH") {
                    Toggle("Alarmă HIGH activă", isOn: $manager.highEnabled)
                    Stepper("Peste \(manager.highThreshold) mg/dL", value: $manager.highThreshold, in: 120...300, step: 5)
                }

                Section("Amânare") {
                    Picker("Durată snooze", selection: $manager.snoozeMinutes) {
                        ForEach([5, 10, 15, 30], id: \.self) { minutes in
                            Text("\(minutes) minute").tag(minutes)
                        }
                    }
                    if let snoozedUntil = manager.snoozedUntil {
                        Text("Alarmă amânată până la \(snoozedUntil.formatted(date: .omitted, time: .shortened)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Afișare") {
                    Toggle("Ecran complet când este posibil", isOn: $manager.fullScreenWhenPossible)
                    Text("iOS poate afișa ecranul complet în aplicație. În fundal sau pe ecranul blocat, sistemul livrează o notificare locală normală cu acțiunea de amânare.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Previzualizare") {
                    Button("Testează ecranul LOW") {
                        manager.preview(.low)
                    }
                    Button("Testează ecranul HIGH") {
                        manager.preview(.high)
                    }
                }
            }
            .navigationTitle("Alarme")
            .onAppear {
                manager.refreshAuthorizationStatus()
            }
        }
    }

    private var notificationSymbol: String {
        manager.authorizationStatus == .denied ? "bell.slash.fill" : "bell.badge.fill"
    }

    private var notificationColor: Color {
        manager.authorizationStatus == .denied ? GlucoseAlarmPalette.low : GlucoseAlarmPalette.accent
    }
}

struct GlucoseAlarmFullScreenView: View {
    let alarm: GlucoseAlarm
    @ObservedObject var manager: GlucoseAlarmManager

    var body: some View {
        ZStack {
            alarm.kind.color
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: alarm.kind.symbol)
                    .font(.system(size: 68))
                Text(alarm.kind.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("\(alarm.glucoseMgDL)")
                    .font(.system(size: 112, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                Text("mg/dL")
                    .font(.title2.weight(.semibold))
                Text(alarm.kind.detail)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                Text(alarm.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .opacity(0.78)

                VStack(spacing: 12) {
                    Button {
                        manager.snooze(alarm)
                    } label: {
                        Label("Amână \(manager.snoozeMinutes) minute", systemImage: "alarm.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(alarm.kind.color)

                    Button("Închide") {
                        manager.dismissActiveAlarm()
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 34)
        }
    }
}

private enum GlucoseAlarmPalette {
    static let accent = Color(red: 0.04, green: 0.55, blue: 0.59)
    static let low = Color(red: 0.76, green: 0.12, blue: 0.18)
    static let high = Color(red: 0.91, green: 0.43, blue: 0.08)
}
