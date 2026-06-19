//
//  QuickCommands.swift
//  Alfred
//
//  Bypasses LLM entirely for basic commands
//

import Foundation
import AppKit

struct QuickCommands {
    
    static func handle(_ query: String) -> String? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // App opening - check if query STARTS WITH "open" or just contains the app name
        if lower.hasPrefix("open ") || lower == "messages" {
            // Extract app name - remove "open " prefix if present
            var appName = lower
            if lower.hasPrefix("open ") {
                appName = String(lower.dropFirst(5))
            }
            
            // Map common names
            let appMappings: [(key: String, bundleId: String)] = [
                ("messages", "Messages"),
                ("safari", "Safari"),
                ("chrome", "Google Chrome"),
                ("mail", "Mail"),
                ("notes", "Notes"),
                ("calendar", "Calendar"),
                ("music", "Music"),
                ("photos", "Photos"),
                ("terminal", "Terminal"),
                ("finder", "Finder")
            ]
            
            // Check if appName matches any key in mappings
            for (key, bundleId) in appMappings {
                if appName == key || appName.contains(key) {
                    openApp(bundleId: bundleId, path: getPath(for: bundleId))
                    return "Opening \(bundleId)..."
                }
            }
            
            // Try to open by name directly
            let capitalized = appName.capitalized
            openApp(bundleId: nil, path: "/Applications/\(capitalized).app")
            return "Opening \(capitalized)..."
        }
        
        return nil
    }
    
    private static func openApp(bundleId: String?, path: String) {
        if let bundleId = bundleId,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            app.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
    
    private static func getPath(for bundleId: String) -> String {
        switch bundleId {
        case "Messages": return "/System/Applications/Messages.app"
        case "Safari": return "/System/Applications/Safari.app"
        case "Google Chrome": return "/Applications/Google Chrome.app"
        case "Mail": return "/System/Applications/Mail.app"
        case "Notes": return "/System/Applications/Notes.app"
        case "Calendar": return "/System/Applications/Calendar.app"
        case "Music": return "/System/Applications/Music.app"
        case "Photos": return "/System/Applications/Photos.app"
        case "Terminal": return "/System/Applications/Utilities/Terminal.app"
        case "Finder": return "/System/Library/CoreServices/Finder.app"
        default: return "/Applications/\(bundleId).app"
        }
    }
    
}
