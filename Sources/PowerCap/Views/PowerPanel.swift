import SwiftUI

struct PowerPanel: View {
    @ObservedObject var controller: PowerController
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            appList
            Divider()
            footer
        }
        .frame(width: 340)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            contentHeight = height
        }
        .background(PanelWindowBridge(
            contentHeight: contentHeight,
            onOpen: { controller.panelDidOpen() },
            onClose: { controller.panelDidClose() }
        ))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Power")
                .font(.headline)
            Spacer()
            Group {
                Text("CPU \(PowerFormat.watts(controller.cpuWatts))")
                Text("GPU \(PowerFormat.watts(controller.gpuWatts))")
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var appList: some View {
        if controller.rows.isEmpty {
            Text("No apps running")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                ForEach(controller.rows) { app in
                    AppPowerRow(
                        app: app,
                        onRunShareChange: { controller.setRunShare($0, for: app.id) },
                        onEfficiencyCoresToggle: { controller.toggleEfficiencyCores(for: app.id) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Remove All Limits") {
                controller.removeAllLimits()
            }
            .disabled(!controller.hasSavedLimits)
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { controller.opensAtLogin }, set: { controller.setOpensAtLogin($0) }))
                Divider()
                Button("Quit PowerCap") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: PowerController

    var body: some View {
        Image(systemName: controller.hasActiveLimits ? "bolt.fill" : "bolt")
            .accessibilityLabel(controller.hasActiveLimits ? "PowerCap, limits active" : "PowerCap")
    }
}

enum PowerFormat {
    static func watts(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f W", value) : String(format: "%.1f W", value)
    }
}
