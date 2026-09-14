import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController

    /// Empty means following the system language.
    @AppStorage("settingsLanguage") private var language = ""

    private var selectedLanguage: SettingsLanguage {
        SettingsLanguage(rawValue: language) ?? .preferred
    }

    private func localized(_ key: String) -> String {
        selectedLanguage.localized(key)
    }

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var needsLoginApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsOpenFailed = false
    @State private var isMeasuring = false
    @State private var measurement: String?

    var onQuit: () -> Void

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 14
    /// Only a cap. The panel is short now, and a fixed height left it mostly
    /// empty; the scroll view only earns its keep on a very small screen.
    private static let maximumBodyHeight: CGFloat = 400
    private static let authorURL = URL(string: "https://github.com/sypsyp97")!
    private static let cameraSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    )!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if controller.isSensorAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switches
                        if !hasScreenPermission {
                            permissionNotice
                        }
                        startGroup
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: Self.maximumBodyHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                unavailableNotice
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 12)
            }
            Divider()
            appGroup
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .onAppear {
            hasScreenPermission = CGPreflightScreenCaptureAccess()
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = CGPreflightScreenCaptureAccess()
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mac Duo Pro").font(.title2.weight(.semibold))
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(localized("Lid angle"))
        }
    }

    private var unavailableNotice: some View {
        Text(localized("This Mac has no lid angle sensor. Only some MacBook models have one."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggleRow(
                localized("Depth effect"),
                isOn: $preferences.isEnabled,
                help: localized("Leans the screen away as the lid closes.")
            )
            toggleRow(
                localized("Live rendering"),
                isOn: $preferences.isLivePicture,
                help: localized("Off holds the frame from when the effect started.")
            )
            .disabled(!preferences.isEnabled)
        }
    }

    private var startGroup: some View {
        group(localized("Start")) {
            toggleRow(
                localized("Timeout"),
                isOn: $preferences.isTimeoutEnabled,
                help: localized("Ends the effect once the angle stops changing.")
            )
            slider(
                localized("Start angle"), value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: localized("The effect starts at this angle.")
            )
            slider(
                localized("Viewing distance"), value: $preferences.eyeDistance, in: 30...100, format: "%.0f cm",
                help: localized("Drag until the picture stops leaning away. The number is where that puts your eyes; you do not have to measure it.")
            )
            slider(
                localized("Eye height"), value: $preferences.eyeHeight, in: -10...30, format: "%.0f cm",
                help: localized("How far your eyes are above the middle of the screen.")
            )
            HStack {
                Button(localized("Remember where I sit")) { calibrate() }
                    .disabled(isMeasuring)
                Button(localized("Follow me")) { measure() }
                    .disabled(isMeasuring || preferences.cameraCalibration <= 0)
                Spacer()
            }
            .controlSize(.small)
            description(
                measurement ?? (preferences.cameraCalibration > 0
                    ? localized("The camera will move the slider to match wherever you sit.")
                    : localized("Drag the slider until the picture stops leaning, then let the camera remember that. You never have to know the number."))
            )
            slider(
                localized("Strength"), value: $preferences.effectStrength, in: 0...2, format: "%.0f%%", scale: 100,
                help: localized("How hard the blur and the dimming are pushed. The shape of the picture is solved from the lid and the display either way.")
            )
        }
    }

    private var appGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localized("Language"))
                Spacer()
                Picker("", selection: $language) {
                    Text(localized("System")).tag("")
                    Text(verbatim: "English").tag(SettingsLanguage.english.rawValue)
                    Text(localized("Chinese (Simplified)")).tag(SettingsLanguage.chinese.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(localized("Language"))
            }
            toggleRow(localized("Show angle in menu bar"), isOn: $preferences.showsAngleInMenuBar, help: nil)
            toggleRow(
                localized("Launch at login"),
                isOn: $launchesAtLogin,
                help: needsLoginApproval
                    ? localized("Allow Mac Duo Pro under Login Items & Extensions to finish turning this on.")
                    : nil
            )
            .onChange(of: launchesAtLogin) { _, newValue in
                setLaunchAtLogin(newValue)
            }
            HStack {
                Button(localized("Reset")) { preferences.resetToDefaults() }
                Spacer()
                Button(localized("Quit"), action: onQuit)
            }
            .controlSize(.small)
            .padding(.top, 2)
            HStack(spacing: 0) {
                Text(localized("Made by ")).foregroundStyle(.secondary)
                Link("Yipeng Sun", destination: Self.authorURL)
                    .pointingHand()
                Spacer()
                Text("© 2026 Yipeng Sun").foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            description(help)
        }
    }

    @ViewBuilder
    private func description(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Screen Recording permission is required to show the depth effect."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized("Open System Settings")) {
                    openScreenRecordingSettings()
                }
                .controlSize(.small)
            }
            if settingsOpenFailed {
                Text(localized("Could not open System Settings. Open it manually and enable screen recording for Mac Duo Pro under Privacy & Security."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openScreenRecordingSettings() {
        settingsOpenFailed = false
        Task { @MainActor in
            // macOS only raises its own alert the first time an app identity
            // asks. When it does, the user never has to find the pane.
            if await ScreenSnapshotter.requestPermission() {
                hasScreenPermission = CGPreflightScreenCaptureAccess()
                return
            }
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(Self.screenRecordingSettingsURL, configuration: configuration)
            } catch {
                settingsOpenFailed = true
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .disabled(!preferences.isEnabled)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            description(help)
        }
    }

    /// Looks once through the camera and writes what it finds into the two
    /// sliders. The camera lives in the lid, so this cannot run while the
    /// effect does; it is a calibration, not a live input.
    /// Anchors the camera to a distance the viewer has confirmed, which is
    /// the only way to learn it: the delivered frame's field of view is not
    /// discoverable, and neither is anyone's pupil spacing.
    private func calibrate() {
        isMeasuring = true
        measurement = localized("Sit back, the way you normally do…")
        Task { @MainActor in
            defer { isMeasuring = false }
            do {
                // Reaching for the button pulls a viewer forward, and the
                // whole point is to anchor on where they normally sit.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let separation = try await EyeMeasurement.pupilSeparation()
                preferences.cameraCalibration = preferences.eyeDistance * 10 * separation
                measurement = localized("Remembered. Move around and press Follow me.")
            } catch {
                measurement = error.localizedDescription
                if case EyeMeasurement.Failure.denied = error {
                    NSWorkspace.shared.open(Self.cameraSettingsURL)
                }
            }
        }
    }

    private func measure() {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        let millimetres = CGDisplayScreenSize(displayID)
        guard millimetres.width > 0, screen.frame.width > 0 else { return }
        let perPoint = millimetres.width / Double(screen.frame.width)
        isMeasuring = true
        measurement = localized("Sit back, the way you normally do…")
        Task { @MainActor in
            defer { isMeasuring = false }
            do {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let result = try await EyeMeasurement.measure(
                    calibration: preferences.cameraCalibration,
                    screenHeightPoints: Double(screen.frame.height),
                    millimetresPerPoint: perPoint
                )
                preferences.eyeDistance = min(max(result.distanceMillimetres / 10, 30), 100)
                preferences.eyeHeight = min(max(result.heightAboveCentreMillimetres / 10, -10), 30)
                measurement = String(
                    format: localized("Measured from %d frames."),
                    result.samples
                )
            } catch {
                measurement = error.localizedDescription
                if case EyeMeasurement.Failure.denied = error {
                    NSWorkspace.shared.open(Self.cameraSettingsURL)
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        defer {
            // Always from macOS, never from what was asked for. `register()`
            // succeeds into `.requiresApproval` when the user has yet to allow
            // background items, and a switch left on in that state promises a
            // launch that will not happen.
            let status = SMAppService.mainApp.status
            launchesAtLogin = status == .enabled
            needsLoginApproval = status == .requiresApproval
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diagnostics.geometry.error(
                "login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

private extension View {
    func pointingHand() -> some View {
        modifier(PointingHand())
    }
}

private struct PointingHand: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}
