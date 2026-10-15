import SwiftUI

struct AppPowerRow: View {
    let app: AppPower
    let onRunShareChange: (Double) -> Void
    let onEfficiencyCoresToggle: () -> Void

    private var isDutyCycled: Bool { app.limit.runShare < 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(PowerFormat.watts(app.watts))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Slider(value: runShareBinding, in: 0.1...1.0)
                    .controlSize(.small)
                    .tint(isDutyCycled ? .orange : .gray)
                    .accessibilityLabel("Power limit for \(app.name)")
                Text("\(Int((app.limit.runShare * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(isDutyCycled ? Color.orange : Color.secondary)
                    .frame(width: 38, alignment: .trailing)
                efficiencyCoresButton
            }
            .padding(.leading, 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// Snaps to 5% steps without drawing a tick mark for every step.
    private var runShareBinding: Binding<Double> {
        Binding(
            get: { app.limit.runShare },
            set: { onRunShareChange(min(1.0, max(0.1, ($0 * 20).rounded() / 20))) }
        )
    }

    private var efficiencyCoresButton: some View {
        Button(action: onEfficiencyCoresToggle) {
            Image(systemName: app.limit.efficiencyCoresOnly ? "leaf.fill" : "leaf")
                .foregroundStyle(app.limit.efficiencyCoresOnly ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Low-power mode: runs this app only on the efficiency cores, without pausing it. Uses far less power, but the app gets slower, including its disk and network access.")
        .accessibilityLabel("Efficiency cores only")
        .accessibilityValue(app.limit.efficiencyCoresOnly ? "On" : "Off")
    }
}
