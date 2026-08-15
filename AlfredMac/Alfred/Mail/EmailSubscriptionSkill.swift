//
//  EmailSubscriptionSkill.swift
//  Alfred
//
//  Newsletter sign-up automation: "subscribe me to TechCrunch" becomes a
//  deterministic browser run — open the signup page, find the email field,
//  fill it, submit, and report what came back.
//
//  This is the Alfred-side orchestration layer over BrowserUseClient. Hermes
//  can *also* do sign-ups itself through the browser-use MCP tools registered
//  in ~/.alfred/agent-servers.json (browser_navigate / browser_click /
//  browser_type …) — that path is agentic and page-adaptive. This skill is
//  the deterministic fallback: no model quota, no imagination, just a form
//  filled and submitted, gated on the same safety rules as every other Alfred
//  automation.
//
//  Safety:
//   * Requires BrowserUseClient.isEnabled (default OFF).
//   * Refuses blocked hosts (banks, payment providers) before anything runs.
//   * Requires explicit confirmation to submit — `confirmed: true` only comes
//     from a path where the user actually asked ("subscribe me to X" through
//     the bar or the phone), never from a background tick.

import Foundation

// MARK: - Result

/// What a subscription attempt produced, for the caller to render.
enum SubscriptionOutcome: Sendable {
    /// The form was filled and submitted; `pageText` is what the page showed
    /// after (often a confirmation or "check your email" message).
    case subscribed(pageText: String)
    /// The form was found and filled but submission needs the user's OK.
    /// `pageText` shows what *would* have been submitted.
    case awaitingConfirmation(pageText: String)
    /// No email input existed on the page.
    case noSignupForm(pageText: String)
    /// Automation is off, the site is blocked, or the browser couldn't run.
    case failed(String)
}

// MARK: - Skill

/// Newsletter sign-up orchestration over BrowserUseClient.
@MainActor
final class EmailSubscriptionSkill {

    static let shared = EmailSubscriptionSkill()

    /// The user's own address for the form. Prefers the default mail account;
    /// falls back to any configured account.
    var userEmail: String {
        let accounts = MailManager.shared.accounts
        let def = MailManager.shared.defaultAccountID
        return accounts.first { $0.id == def }?.email
            ?? accounts.first?.email
            ?? ""
    }

    /// Subscribe to a newsletter at `url`. When `email` is empty, the user's
    /// own address (from the mail config) is used.
    ///
    /// `confirmed` is the submission gate: false (the default) fills the form
    /// and stops; true (an explicit "subscribe me to X" ask) submits.
    func subscribe(url: String, email: String = "", confirmed: Bool = false) async -> SubscriptionOutcome {
        let client = BrowserUseClient.shared
        guard client.isEnabled else {
            return .failed("Browser automation is off — turn it on in Alfred's Settings (BROWSER section) first.")
        }
        guard !BrowserUseClient.isBlocked(url: url) else {
            client.logAudit("subscribe-blocked", url: url, detail: "refused: blocked host")
            return .failed(BrowserUseClient.refusalMessage(for: url))
        }

        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return .failed("No email address to subscribe with — set one up in Mail settings, or pass one.")
        }
        guard address.contains("@"), address.contains(".") else {
            return .failed("That doesn't look like an email address.")
        }

        switch await client.fillEmailAndSubmit(url: url, email: address, confirmed: confirmed) {
        case .submitted(let text):
            return .subscribed(pageText: Self.tidy(text))
        case .needsConfirmation(let text):
            return .awaitingConfirmation(pageText: Self.tidy(text))
        case .noEmailField(let text):
            return .noSignupForm(pageText: Self.tidy(text))
        case .refused(let message), .failed(let message):
            return .failed(message)
        }
    }

    /// A page's worth of scraped text is noisy — trim to the useful core for
    /// the result line and the briefing.
    private static func tidy(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Keep the first ~12 meaningful lines; a "check your inbox" message is
        // almost always near the top of the post-submit page.
        return lines.prefix(12).joined(separator: "\n")
    }
}
