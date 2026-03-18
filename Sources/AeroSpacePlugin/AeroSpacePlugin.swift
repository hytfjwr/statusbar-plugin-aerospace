import StatusBarKit

@MainActor
public struct AeroSpacePlugin: StatusBarPlugin {
    public let manifest = PluginManifest(
        id: "com.statusbar.aerospace",
        name: "AeroSpace"
    )

    public let widgets: [any StatusBarWidget]

    public init() {
        widgets = [WorkspaceWidget()]
    }
}

// MARK: - Plugin Factory

@_cdecl("createStatusBarPlugin")
public func createStatusBarPlugin() -> UnsafeMutableRawPointer {
    let box = PluginBox { AeroSpacePlugin() }
    return Unmanaged.passRetained(box).toOpaque()
}
