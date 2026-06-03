import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LibreCRWidgetBundle: WidgetBundle {
    var body: some Widget {
        LibreCRGlucoseLiveActivityWidget()
    }
}

struct LibreCRGlucoseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        LibreCRGlucoseActivityConfiguration()
            .supplementalActivityFamilies([.small, .medium])
    }
}

private struct LibreCRGlucoseActivityConfiguration: WidgetConfiguration {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LibreCRGlucoseActivityAttributes.self) { context in
            LibreCRLiveActivityView(context: context)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LibreCRLiveActivityTitle()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LibreCRLiveActivityDelta(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .lastTextBaseline) {
                        LibreCRLiveActivityGlucose(state: context.state, size: 46)
                        Spacer()
                        Text(context.state.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "drop.fill")
                    .foregroundStyle(LibreCRLiveActivityStyle.accent)
            } compactTrailing: {
                Text("\(context.state.glucoseMgDL)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: true, vertical: false)
            } minimal: {
                Image(systemName: LibreCRLiveActivityStyle.trendSymbol(context.state.trend))
                    .foregroundStyle(LibreCRLiveActivityStyle.accent)
            }
            .keylineTint(LibreCRLiveActivityStyle.accent)
        }
    }
}

private struct LibreCRLiveActivityView: View {
    @Environment(\.activityFamily) private var activityFamily

    let context: ActivityViewContext<LibreCRGlucoseActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            LibreCRSmallLiveActivityView(context: context)
        case .medium:
            LibreCRMediumLiveActivityView(context: context)
        @unknown default:
            LibreCRMediumLiveActivityView(context: context)
        }
    }
}

private struct LibreCRMediumLiveActivityView: View {
    let context: ActivityViewContext<LibreCRGlucoseActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                LibreCRLiveActivityTitle()
                LibreCRLiveActivityGlucose(state: context.state, size: 52)
            }
            .layoutPriority(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 9) {
                LibreCRLiveActivityDelta(state: context.state)
                Text(context.state.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

private struct LibreCRSmallLiveActivityView: View {
    let context: ActivityViewContext<LibreCRGlucoseActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(context.state.glucoseMgDL)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: true, vertical: false)
                Text("mg/dL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 5) {
                Image(systemName: LibreCRLiveActivityStyle.trendSymbol(context.state.trend))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LibreCRLiveActivityStyle.trendColor(context.state.trend))
                Text(LibreCRLiveActivityStyle.shortDeltaText(context.state.deltaMgDL))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(12)
    }
}

private struct LibreCRLiveActivityTitle: View {
    var body: some View {
        Label("LibreCR", systemImage: "waveform.path.ecg")
            .font(.caption.weight(.semibold))
            .foregroundStyle(LibreCRLiveActivityStyle.accent)
    }
}

private struct LibreCRLiveActivityGlucose: View {
    let state: LibreCRGlucoseActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 7) {
            Text("\(state.glucoseMgDL)")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
            Text("mg/dL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: LibreCRLiveActivityStyle.trendSymbol(state.trend))
                .font(.headline.weight(.bold))
                .foregroundStyle(LibreCRLiveActivityStyle.trendColor(state.trend))
        }
    }
}

private struct LibreCRLiveActivityDelta: View {
    let state: LibreCRGlucoseActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Delta")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(LibreCRLiveActivityStyle.deltaText(state.deltaMgDL))
                .font(.system(.headline, design: .rounded, weight: .bold))
        }
    }
}

private enum LibreCRLiveActivityStyle {
    static let accent = Color(red: 0.04, green: 0.55, blue: 0.59)

    static func deltaText(_ delta: Int?) -> String {
        guard let delta else {
            return "--"
        }
        return String(format: "%+d mg/dL", delta)
    }

    static func shortDeltaText(_ delta: Int?) -> String {
        guard let delta else {
            return "--"
        }
        return String(format: "%+d", delta)
    }

    static func trendSymbol(_ rawValue: UInt8) -> String {
        switch rawValue {
        case 1: return "arrow.down"
        case 2: return "arrow.down.right"
        case 3: return "arrow.right"
        case 4: return "arrow.up.right"
        case 5: return "arrow.up"
        default: return "questionmark"
        }
    }

    static func trendColor(_ rawValue: UInt8) -> Color {
        switch rawValue {
        case 1, 5: return .red
        case 2, 4: return .orange
        case 3: return .green
        default: return .secondary
        }
    }
}
