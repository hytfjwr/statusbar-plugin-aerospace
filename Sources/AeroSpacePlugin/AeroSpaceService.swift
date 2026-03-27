import Foundation
import OSLog
import StatusBarKit

private let logger = Logger(subsystem: "com.statusbar", category: "AeroSpaceService")

final class AeroSpaceService: @unchecked Sendable {
    struct WorkspaceData {
        let id: String
        let apps: [String]
        let monitorID: Int?
    }

    func fetchFocusedWorkspace() async -> String {
        do {
            return try await ShellCommand
                .run("aerospace", arguments: ["list-workspaces", "--focused"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.debug("fetchFocusedWorkspace failed: \(error.localizedDescription)")
            return ""
        }
    }

    func fetchWorkspaces() async -> [WorkspaceData] {
        do {
            let windowsJSON = try await ShellCommand
                .run(
                    "aerospace",
                    arguments: [
                        "list-windows", "--all", "--json",
                        "--format", "%{workspace}%{app-name}%{monitor-appkit-nsscreen-screens-id}",
                    ]
                )

            // Parse windows JSON to derive workspace list, app mappings, and monitor IDs
            var appsByWorkspace: [String: [String]] = [:]
            var seenApps: [String: Set<String>] = [:]
            var monitorByWorkspace: [String: Int] = [:]
            if let data = windowsJSON.data(using: .utf8),
               let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            {
                for window in windows {
                    guard let ws = window["workspace"] as? String else { continue }
                    if let app = window["app-name"] as? String,
                       seenApps[ws, default: []].insert(app).inserted
                    {
                        appsByWorkspace[ws, default: []].append(app)
                    }
                    if let monitor = window["monitor-appkit-nsscreen-screens-id"] as? Int {
                        monitorByWorkspace[ws] = monitor
                    }
                }
            }

            // Sort: numeric first (1-9), then alpha (A-Z)
            let sorted = appsByWorkspace.keys.sorted { a, b in
                let aNum = Int(a)
                let bNum = Int(b)
                if let an = aNum, let bn = bNum {
                    return an < bn
                }
                if aNum != nil {
                    return true
                }
                if bNum != nil {
                    return false
                }
                return a < b
            }

            return sorted.map { ws in
                WorkspaceData(id: ws, apps: appsByWorkspace[ws] ?? [], monitorID: monitorByWorkspace[ws])
            }
        } catch {
            logger.debug("fetchWorkspaces failed: \(error.localizedDescription)")
            return []
        }
    }
}
