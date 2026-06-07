import SwiftUI

@main
struct LibreCRWatchApp: App {
    @StateObject private var model = WatchSensorViewModel()

    var body: some Scene {
        WindowGroup {
            WatchDashboardView(model: model)
        }
    }
}

struct WatchDashboardView: View {
    @ObservedObject var model: WatchSensorViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("LibreCR", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .foregroundStyle(WatchPalette.accent)
                    Spacer()
                    Circle()
                        .fill(model.isConnected ? WatchPalette.green : WatchPalette.orange)
                        .frame(width: 8, height: 8)
                }

                if let reading = model.latestReading {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .lastTextBaseline, spacing: 5) {
                            Text("\(reading.glucoseMgDL)")
                                .font(.system(size: 54, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                            Text("mg/dL")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 7) {
                            Label(reading.trendLabel, systemImage: reading.trendSymbol)
                            Text(model.deltaText)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reading.trendColor)
                        Text(reading.receivedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WatchPalette.card, in: RoundedRectangle(cornerRadius: 17))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("-- mg/dL")
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text(model.hasSensorConfiguration
                             ? "Aștept prima valoare de la senzor."
                             : "Deschide aplicația LibreCR pe iPhone pentru transferul senzorului.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WatchPalette.card, in: RoundedRectangle(cornerRadius: 17))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.statusText)
                        .font(.caption)
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.orange)
                    }
                }

                Button {
                    model.reconnect()
                } label: {
                    Label("Reconectează", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchPalette.accent)
                .disabled(!model.hasSensorConfiguration || !model.directConnectionEnabled || model.isConnecting)

                Toggle(isOn: Binding(
                    get: { model.workoutModeActive || model.workoutModeStarting },
                    set: { model.setWorkoutModeEnabled($0) }
                )) {
                    Label("AOD workout", systemImage: "figure.run.circle")
                }
                .font(.caption.weight(.semibold))
                .disabled(model.workoutModeStarting)

                Text(model.workoutModeStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reconnectIfNeeded()
            }
        }
    }
}

private enum WatchPalette {
    static let accent = Color(red: 0.04, green: 0.55, blue: 0.59)
    static let green = Color(red: 0.13, green: 0.64, blue: 0.43)
    static let orange = Color(red: 0.94, green: 0.55, blue: 0.20)
    static let card = Color.white.opacity(0.12)
}
