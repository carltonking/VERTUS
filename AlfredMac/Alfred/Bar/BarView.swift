import AppKit
import SwiftUI

struct BarView: View {
    let onSubmit: (String) -> Void
    @Binding var responseText: String
    @Binding var isProcessing: Bool

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    // Must match BarWindow panelWidth and BarWindow convenience init width
    static let barWidth: CGFloat = 740

    // Fixed heights — must stay in sync with observeBarSizing in AlfredApp
    static let inputRowHeight: CGFloat = 74
    static let loadingRowHeight: CGFloat = 50
    static let maxResponseHeight: CGFloat = 420

    static func responseHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 50 }
        let textWidth: CGFloat = 700
        let charWidth: CGFloat = 7.5
        let charsPerLine = max(Int(textWidth / charWidth), 1)
        let lineCount = max(text.count / charsPerLine, 1)
        let lineHeight: CGFloat = 20
        let verticalPadding: CGFloat = 32
        return min(CGFloat(lineCount) * lineHeight + verticalPadding, maxResponseHeight)
    }

    private let cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.black.opacity(0.78))
                .shadow(color: .black.opacity(0.5), radius: 32, x: 0, y: 12)

            VStack(spacing: 0) {
                inputRow
                    .frame(height: Self.inputRowHeight)

                if isProcessing || !responseText.isEmpty {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                    if responseText.isEmpty {
                        loadingRow
                            .frame(height: Self.loadingRowHeight)
                    } else {
                        responseArea
                            .frame(minHeight: 50, maxHeight: Self.maxResponseHeight)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .frame(width: Self.barWidth)
        .onAppear { inputFocused = true }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(inputFocused ? 0.18 : 0.10))
                if let logo = Self.logoImage {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 34, height: 34)

            TextField("Ask Alfred anything…", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit { submit() }
                .tint(.white)

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 20, height: 20)
            } else if !inputText.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.15), value: inputText.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: isProcessing)
    }

    // MARK: - Loading row

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
            Text("Working…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Response area (5 lines tall, scrollable, auto-scrolls during streaming)

    private var responseArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(responseText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: responseText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        onSubmit(text)
    }

    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "alfred-small-logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
