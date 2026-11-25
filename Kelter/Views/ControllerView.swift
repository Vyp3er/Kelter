import GameController
import SwiftUI
import WineKit

/// Erkennt Controller über Apples GameController-Framework.
@Observable
final class ControllerMonitor {
    private(set) var controllers: [GCController] = []
    var selectedIndex = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        // Auch Eingaben annehmen, wenn Kelter nicht vorne ist (z. B. während ein Spiel läuft).
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func refresh() {
        controllers = GCController.controllers()
        if selectedIndex >= controllers.count { selectedIndex = 0 }
    }

    var selected: GCController? {
        controllers.indices.contains(selectedIndex) ? controllers[selectedIndex] : nil
    }
}

/// „Controller“ in der Seitenleiste: verbundene Controller, Live-Test, Tipps für Wine.
struct ControllerView: View {
    @Environment(AppModel.self) private var model
    @State private var monitor = ControllerMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Controller").font(.largeTitle.bold())
                    Text("Verbinde Xbox- oder PlayStation-Controller per Bluetooth (Systemeinstellungen → Bluetooth) oder Kabel. Was hier erscheint, sieht macOS.")
                        .foregroundStyle(.secondary)
                }

                if monitor.controllers.isEmpty {
                    ContentUnavailableView {
                        Label("Kein Controller verbunden", systemImage: "gamecontroller")
                    } description: {
                        Text("Controller einschalten und koppeln – er erscheint dann automatisch.")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Picker("Controller", selection: $monitor.selectedIndex) {
                        ForEach(Array(monitor.controllers.enumerated()), id: \.offset) { index, controller in
                            Text(controller.vendorName ?? controller.productCategory).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)

                    if let controller = monitor.selected {
                        ControllerInfoView(controller: controller)
                        GroupBox("Live-Test – drück Tasten und bewege die Sticks") {
                            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                                if let pad = controller.extendedGamepad {
                                    GamepadLiveView(pad: pad)
                                } else {
                                    Text("Dieser Controller hat kein erweitertes Gamepad-Profil.").foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                        }
                    }
                }

                GroupBox("Wenn ein Spiel den Controller nicht erkennt") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wine reicht Controller über SDL an Windows-Spiele weiter. Pro Bottle lässt sich unter „Erweitert → Controller“ einstellen, wie:")
                        ForEach(ControllerMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName).bold()
                                Text(mode.explanation).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text("Tipp: Erscheint der Controller hier, im Spiel aber nicht (oder doppelt), probier „Über den macOS-Controllerdienst“.")
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if !model.bottles.isEmpty {
                    GroupBox("Joystick-Einstellungen einer Bottle öffnen") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Zeigt, welche Controller Windows-Spiele in der Bottle sehen – mit eigenem Tastentest.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(model.bottles) { bottle in
                                HStack {
                                    Label(bottle.name, systemImage: "wineglass")
                                    Text(bottle.settings.controllerMode.displayName).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Öffnen") { model.launch(.joystick, in: bottle) }
                                        .disabled(!bottle.isInitialized || model.engine(for: bottle)?.isComplete != true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Controller")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

private struct ControllerInfoView: View {
    let controller: GCController

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.vendorName ?? "Controller").font(.title3.bold())
                Text(controller.productCategory).foregroundStyle(.secondary)
                if let battery = controller.battery {
                    Label("Akku \(Int(battery.batteryLevel * 100)) %\(battery.batteryState == .charging ? " (lädt)" : "")", systemImage: "battery.75percent")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        let category = controller.productCategory.lowercased()
        if category.contains("xbox") { return "xbox.logo" }
        if category.contains("dual") || category.contains("playstation") { return "playstation.logo" }
        return "gamecontroller.fill"
    }
}

/// Zeigt Tasten, Trigger und Sticks live an.
private struct GamepadLiveView: View {
    let pad: GCExtendedGamepad

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                TriggerBar(title: label(pad.leftTrigger, "LT"), value: pad.leftTrigger.value)
                ButtonDot(title: label(pad.leftShoulder, "LB"), pressed: pad.leftShoulder.isPressed)
                StickView(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value,
                          pressed: pad.leftThumbstickButton?.isPressed ?? false)
                DPadView(pad: pad.dpad)
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if let options = pad.buttonOptions {
                        ButtonDot(title: label(options, "View"), pressed: options.isPressed)
                    }
                    if let home = pad.buttonHome {
                        ButtonDot(title: label(home, "Home"), pressed: home.isPressed)
                    }
                    ButtonDot(title: label(pad.buttonMenu, "Menu"), pressed: pad.buttonMenu.isPressed)
                }
                FaceButtons(pad: pad)
            }
            VStack(spacing: 10) {
                TriggerBar(title: label(pad.rightTrigger, "RT"), value: pad.rightTrigger.value)
                ButtonDot(title: label(pad.rightShoulder, "RB"), pressed: pad.rightShoulder.isPressed)
                StickView(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value,
                          pressed: pad.rightThumbstickButton?.isPressed ?? false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ element: GCControllerElement, _ fallback: String) -> String {
        element.localizedName ?? fallback
    }
}

private struct FaceButtons: View {
    let pad: GCExtendedGamepad

    var body: some View {
        VStack(spacing: 4) {
            face(pad.buttonY, "Y")
            HStack(spacing: 28) {
                face(pad.buttonX, "X")
                face(pad.buttonB, "B")
            }
            face(pad.buttonA, "A")
        }
    }

    private func face(_ button: GCControllerButtonInput, _ fallback: String) -> some View {
        ZStack {
            Circle()
                .fill(button.isPressed ? Color.accentColor : Color.secondary.opacity(0.15))
                .frame(width: 40, height: 40)
            if let symbol = button.sfSymbolsName {
                Image(systemName: symbol).foregroundStyle(button.isPressed ? .white : .primary)
            } else {
                Text(fallback).bold().foregroundStyle(button.isPressed ? .white : .primary)
            }
        }
    }
}

private struct ButtonDot: View {
    let title: String
    let pressed: Bool

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(pressed ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(pressed ? .white : .primary)
    }
}

private struct TriggerBar: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.caption)
            ProgressView(value: Double(value)).frame(width: 90)
        }
    }
}

private struct StickView: View {
    let x: Float
    let y: Float
    let pressed: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 2)
            Circle()
                .fill(pressed ? Color.accentColor : Color.primary.opacity(0.7))
                .frame(width: 18, height: 18)
                .offset(x: CGFloat(x) * 32, y: CGFloat(-y) * 32)
        }
        .frame(width: 84, height: 84)
    }
}

private struct DPadView: View {
    let pad: GCControllerDirectionPad

    var body: some View {
        VStack(spacing: 2) {
            arrow("chevron.up", pad.up.isPressed)
            HStack(spacing: 18) {
                arrow("chevron.left", pad.left.isPressed)
                arrow("chevron.right", pad.right.isPressed)
            }
            arrow("chevron.down", pad.down.isPressed)
        }
    }

    private func arrow(_ symbol: String, _ pressed: Bool) -> some View {
        Image(systemName: symbol)
            .frame(width: 24, height: 24)
            .background(pressed ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(pressed ? .white : .primary)
    }
}
