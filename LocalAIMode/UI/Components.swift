import SwiftUI

extension MemoryPressureLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

extension ThermalLevel {
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

extension ActivityEvent.Kind {
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Rounded material container used throughout the dashboard.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var detail: String? = nil
    var symbol: String
    var tint: Color = .accentColor
    var fraction: Double? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(TintedIconLabelStyle(tint: tint))
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(tint)
                        .controlSize(.small)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

struct TintedIconLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct Banner: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    var actions: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actions { actions.padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

/// The large central ON/OFF control.
struct ModeToggleButton: View {
    var state: ModeState
    var action: () -> Void
    @State private var spin = false

    private var isOn: Bool { state == .active }
    private var busy: Bool { state.isTransitioning || state == .awaitingConfirmation }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn
                          ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(.quaternary))
                    .shadow(color: isOn ? .purple.opacity(0.45) : .clear, radius: 18)
                if busy {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        .padding(4)
                        .onAppear { spin = true }
                        .onDisappear { spin = false }
                }
                Image(systemName: isOn ? "bolt.fill" : "power")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .symbolEffect(.bounce, value: isOn)
            }
            .frame(width: 112, height: 112)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy || state == .recoveryNeeded)
        .help(isOn ? "Disable AI Mode" : "Enable AI Mode")
        .accessibilityLabel(isOn ? "Disable AI Mode" : "Enable AI Mode")
        .animation(.spring(duration: 0.4), value: isOn)
    }
}

extension View {
    /// Tells the monitor a live view is visible so it samples faster; slows down again when hidden.
    func liveMetrics(_ monitor: MemoryMonitor) -> some View {
        onAppear { monitor.setVisible(true) }
            .onDisappear { monitor.setVisible(false) }
    }
}
