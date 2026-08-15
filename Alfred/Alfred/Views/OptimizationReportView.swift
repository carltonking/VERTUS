//
//  OptimizationReportView.swift
//  Alfred
//
//  The "Alfred Improvement" report: how the self-optimization loop is doing.
//  Shows the week-over-week rating trend per domain, the active learned rules,
//  and a Compile Now trigger for when the weekly cadence isn't soon enough.
//  Reached from Settings → Optimization.
//

import SwiftUI

struct OptimizationReportView: View {
    @Environment(\.palette) private var palette

    @State private var report: OptimizationReportPayload?
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        ZStack {
            palette.background

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch loadState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    case .failed(let message):
                        emptyState(message)
                    case .loaded:
                        if let report {
                            content(report)
                        } else {
                            emptyState("No ratings yet. Rate Alfred's outputs and check back after a compile pass.")
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Alfred Improvement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ report: OptimizationReportPayload) -> some View {
        // Headline: the week-over-week delta.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                Text("Week over week")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }

            let delta = report.weekDelta
            let deltaText = String(format: "%+.1f", delta)
            Text(deltaText == "+0.0" || deltaText == "-0.0"
                 ? "Average rating holding steady at \(String(format: "%.1f", report.averageRating)) stars"
                 : "Average rating \(delta >= 0 ? "up" : "down") \(String(format: "%.1f", abs(delta))) stars to \(String(format: "%.1f", report.averageRating))")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)

            if report.totalRatings > 0 {
                Text("\(report.totalRatings) domain\(report.totalRatings == 1 ? "" : "s") rated this week")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }
        }
        .card(palette)

        // Per-domain trend.
        if !report.perKind.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("By domain", icon: "square.grid.2x2")
                ForEach(report.perKind) { score in
                    kindRow(score)
                }
            }
            .card(palette)
        }

        // Active optimizations.
        if !report.activeOptimizations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Active optimizations (\(report.activeOptimizations.count))", icon: "sparkles")
                ForEach(report.activeOptimizations, id: \.self) { rule in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(palette.accentBright)
                            .padding(.top, 6)
                        Text(rule)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .card(palette)
        }

        // Manual trigger.
        Button {
            compileNow()
        } label: {
            HStack {
                Text("Compile Now")
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(palette.accentGradient)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)

        Text("Optimization data stays on your Mac — nothing is sent to the cloud.")
            .font(.system(size: 12))
            .foregroundStyle(palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func kindRow(_ score: OptimizationKindScorePayload) -> some View {
        HStack {
            Text(score.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Spacer()
            if score.samples > 0 {
                Text(score.previous > 0
                     ? "\(String(format: "%.1f", score.previous)) → \(String(format: "%.1f", score.current))"
                     : String(format: "%.1f", score.current))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(deltaColor(score.current - score.previous))
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
            }
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.accentBright)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
            Spacer()
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(palette.textFaint)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func deltaColor(_ delta: Double) -> Color {
        if delta > 0.05 { return palette.success }
        if delta < -0.05 { return palette.danger }
        return palette.textSecondary
    }

    // MARK: - Loading

    private func load() async {
        loadState = .loading
        if AlfredWebSocketClient.shared.isConnected {
            if let report = await AlfredWebSocketClient.shared.optimizationReport() {
                self.report = report
                loadState = .loaded
            } else {
                loadState = .failed("Couldn't reach the Mac's optimization loop.")
            }
        } else {
            loadState = .failed("Not connected to the Mac. Connect in Settings, then come back.")
        }
    }

    private func compileNow() {
        Task {
            loadState = .loading
            if let fresh = await AlfredWebSocketClient.shared.optimizeNow() {
                report = fresh
                loadState = .loaded
            } else {
                loadState = .failed("The compile pass didn't answer. Is the Mac awake?")
            }
        }
    }
}

/// A card background matching Home's `SummaryCard` so report sections read as
/// one surface family.
private extension View {
    func card(_ palette: Palette) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1)
            )
    }
}
