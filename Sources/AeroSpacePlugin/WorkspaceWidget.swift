import AppKit
import StatusBarKit
import SwiftUI

// MARK: - WorkspaceWidget

@MainActor
@Observable
public final class WorkspaceWidget: StatusBarWidget {
    public let id = "workspace"
    public let position: WidgetPosition = .left
    public var updateInterval: TimeInterval? { Self.fallbackInterval }
    public var sfSymbolName: String { "square.grid.3x3" }

    private var fallbackTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private let service = AeroSpaceService()
    private var workspaces: [WorkspaceInfo] = []
    private var focusedWorkspace = ""
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var updateTask: Task<Void, Never>?
    private var showAppIcons = true
    private var appIconSize = 16.0
    private var showEmptySpaces = false
    private var activeBackgroundColor = WorkspaceSettings.defaultActiveBackgroundColor
    private var workspaceObservers: [NSObjectProtocol] = []

    public struct WorkspaceInfo: Identifiable, Equatable {
        public let id: String
        public let apps: [String]
        public let isFocused: Bool
        public let monitorID: Int?
    }

    public init() {}

    public func start() {
        applySettings()
        update()
        startFallbackTimer()
        startFileMonitoring()
        startWorkspaceNotifications()
        observeSettings()
    }

    public func stop() {
        fallbackTimer?.cancel()
        debounceWork?.cancel()
        stopFileMonitoring()
        stopWorkspaceNotifications()
    }

    public var hasSettings: Bool { true }

    public func settingsBody() -> some View {
        WorkspaceWidgetSettings()
    }

    private func applySettings() {
        let settings = WorkspaceSettings.shared
        showAppIcons = settings.showAppIcons
        appIconSize = settings.appIconSize
        showEmptySpaces = settings.showEmptySpaces
        activeBackgroundColor = settings.activeBackgroundColor
    }

    private static let fallbackInterval: TimeInterval = 60
    private static let debounceInterval: TimeInterval = 0.3
    /// Delay for a follow-up update after app launch/terminate, giving AeroSpace
    /// time to register the new window before we re-query.
    private static let launchSettleDelay: TimeInterval = 2.0

    private func startFallbackTimer() {
        fallbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.fallbackInterval, repeating: Self.fallbackInterval)
        timer.setEventHandler { [weak self] in self?.scheduleUpdate() }
        timer.resume()
        fallbackTimer = timer
    }

    /// Debounced update — coalesces rapid events into a single CLI fetch.
    private func scheduleUpdate() {
        debounceWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.update() }
        debounceWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Delayed follow-up update for app launch/terminate events.
    /// AeroSpace may not have registered the window immediately, so we
    /// re-query after a short settle period.
    private func scheduleDelayedUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchSettleDelay) { [weak self] in
            self?.scheduleUpdate()
        }
    }

    // MARK: - NSWorkspace Notifications

    private func startWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        // App lifecycle events — schedule an immediate update plus a delayed
        // follow-up because AeroSpace may not have registered the window yet.
        let lifecycleNames: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in lifecycleNames {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleUpdate()
                    self?.scheduleDelayedUpdate()
                }
            }
            workspaceObservers.append(observer)
        }

        // Activation / space-change events — catch app switches and macOS
        // space transitions that don't involve a launch or terminate.
        let activationNames: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in activationNames {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleUpdate()
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func stopWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func observeSettings() {
        withObservationTracking {
            let s = WorkspaceSettings.shared
            _ = s.showAppIcons
            _ = s.appIconSize
            _ = s.showEmptySpaces
            _ = s.activeBackgroundColor
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.update()
                self?.observeSettings()
            }
        }
    }

    private func startFileMonitoring() {
        let path = AeroSpaceService.focusedWorkspaceFile

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.onFileChanged()
        }

        let capturedFD = fileDescriptor
        source.setCancelHandler {
            if capturedFD >= 0 {
                close(capturedFD)
            }
        }

        source.resume()
        fileMonitorSource = source
    }

    private func stopFileMonitoring() {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
    }

    private func onFileChanged() {
        let path = AeroSpaceService.focusedWorkspaceFile
        Task.detached {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let newFocused = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newFocused.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, newFocused != focusedWorkspace else { return }
                focusedWorkspace = newFocused
                scheduleUpdate()
            }
        }
    }

    private func update() {
        updateTask?.cancel()
        updateTask = Task { @MainActor in
            let info = await service.fetchWorkspaces()
            guard !Task.isCancelled else { return }
            let newWorkspaces: [WorkspaceInfo] = info.workspaces.compactMap { ws in
                if !self.showEmptySpaces, ws.apps.isEmpty, ws.id != info.focused {
                    return nil
                }
                return WorkspaceInfo(
                    id: ws.id,
                    apps: ws.apps,
                    isFocused: ws.id == info.focused,
                    monitorID: ws.monitorID
                )
            }
            if info.focused != self.focusedWorkspace {
                self.focusedWorkspace = info.focused
            }
            if newWorkspaces != self.workspaces {
                self.workspaces = newWorkspaces
            }
        }
    }

    public func body() -> some View {
        WorkspaceContainerView(
            workspaces: workspaces,
            showAppIcons: showAppIcons,
            appIconSize: appIconSize,
            activeBackgroundColor: activeBackgroundColor
        )
    }
}

// MARK: - WorkspaceContainerView

private struct WorkspaceContainerView: View {
    let workspaces: [WorkspaceWidget.WorkspaceInfo]
    let showAppIcons: Bool
    let appIconSize: CGFloat
    let activeBackgroundColor: String
    @Environment(\.screenIndex) private var screenIndex

    init(
        workspaces: [WorkspaceWidget.WorkspaceInfo], showAppIcons: Bool, appIconSize: Double,
        activeBackgroundColor: String
    ) {
        self.workspaces = workspaces
        self.showAppIcons = showAppIcons
        self.appIconSize = CGFloat(appIconSize)
        self.activeBackgroundColor = activeBackgroundColor
    }

    var body: some View {
        // aerospace monitor ID is 1-based, screenIndex is 0-based
        let monitor = screenIndex + 1
        let filtered = workspaces.filter { ws in
            (ws.monitorID ?? 1) == monitor
        }
        HStack(spacing: 4) {
            ForEach(filtered) { ws in
                WorkspaceItemView(
                    workspace: ws, showAppIcons: showAppIcons, appIconSize: appIconSize,
                    activeBackgroundColor: activeBackgroundColor
                ) {
                    Task {
                        try? await ShellCommand.run("aerospace", arguments: ["workspace", ws.id])
                    }
                }
            }
        }
    }
}

// MARK: - WorkspaceItemView

private struct WorkspaceItemView: View {
    let workspace: WorkspaceWidget.WorkspaceInfo
    let showAppIcons: Bool
    let appIconSize: CGFloat
    let activeBackgroundColor: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(workspace.id)
                .font(Theme.labelFont)

            if showAppIcons, !workspace.apps.isEmpty {
                ForEach(workspace.apps, id: \.self) { app in
                    AppIconView(appName: app, size: appIconSize)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .foregroundStyle(workspace.isFocused ? .primary : .secondary)
        .background(
            workspace.isFocused
                ? RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hex: activeBackgroundColor).opacity(0.35))
                : nil
        )
        .glassEffect(
            workspace.isFocused ? .regular.interactive() : .regular,
            in: .rect(cornerRadius: 5)
        )
        .animation(.easeInOut(duration: 0.2), value: workspace.isFocused)
        .onTapGesture { onTap() }
    }
}

// MARK: - WorkspaceWidgetSettings

struct WorkspaceWidgetSettings: View {
    @State private var showAppIcons: Bool
    @State private var appIconSize: Double
    @State private var showEmptySpaces: Bool
    @State private var activeBackgroundColor: Color

    init() {
        let s = WorkspaceSettings.shared
        _showAppIcons = State(initialValue: s.showAppIcons)
        _appIconSize = State(initialValue: s.appIconSize)
        _showEmptySpaces = State(initialValue: s.showEmptySpaces)
        _activeBackgroundColor = State(initialValue: Color(hex: s.activeBackgroundColor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Display
            VStack(alignment: .leading, spacing: 8) {
                Text("Display")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle("Show App Icons", isOn: $showAppIcons)
                    .onChange(of: showAppIcons) { _, newValue in
                        WorkspaceSettings.shared.showAppIcons = newValue
                    }

                if showAppIcons {
                    HStack {
                        Text("Icon Size")
                        Spacer()
                        Picker("", selection: $appIconSize) {
                            Text("12").tag(12.0)
                            Text("14").tag(14.0)
                            Text("16").tag(16.0)
                            Text("18").tag(18.0)
                            Text("20").tag(20.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    .onChange(of: appIconSize) { _, newValue in
                        WorkspaceSettings.shared.appIconSize = newValue
                    }
                }

                Toggle("Show Empty Workspaces", isOn: $showEmptySpaces)
                    .onChange(of: showEmptySpaces) { _, newValue in
                        WorkspaceSettings.shared.showEmptySpaces = newValue
                    }
            }

            // Appearance
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ColorPicker("Active Background", selection: $activeBackgroundColor, supportsOpacity: false)
                    .onChange(of: activeBackgroundColor) { _, newValue in
                        WorkspaceSettings.shared.activeBackgroundColor = newValue.hexString
                    }
            }
        }
    }
}

// MARK: - Color Hex Helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else {
            return WorkspaceSettings.defaultActiveBackgroundColor
        }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
