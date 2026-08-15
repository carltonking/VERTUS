//
//  PushRegistration.swift
//  AlfredMacApp
//
//  Stub of the iOS PushRegistration (Alfred/Alfred/Services/PushRegistration.swift).
//  macOS has no APNs loop to register for a companion app that lives on the
//  same machine as the Mac brain — the socket is already the push channel.
//  The API surface is kept identical so an iOS-style lifecycle hook compiles as-is.
//

import Foundation

@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Has this install successfully registered a token with its current server?
    private(set) var registered = false

    /// No-op on macOS: there is no remote-notification registration to request.
    func request() async {
        // Intentionally empty — the Mac companion app is always "with" the Mac.
    }

    /// No-op on macOS; kept for shape parity with the iOS delegate hook.
    func tokenDidArrive(_ token: String) async {
        // Intentionally empty.
    }
}
