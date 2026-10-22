import AppKit
import SwiftUI

/// Two-line, font-measured cues. The presenter owns reading time and the FIFO;
/// the view never clips text or binds directly to the latest model paragraph.
struct CaptionView: View {
    @Bindable var engine: TranslatorEngine
    @Bindable private var prefs = Preferences.shared
    @State private var isHovered: Bool = false

    private var translationFontSize: CGFloat { CGFloat(prefs.captionFontSize) }
    private var sourceFontSize: CGFloat { CGFloat(prefs.captionSourceFontSize) }
    private var isCompact: Bool { prefs.captionDisplayMode == .compact }
    private var shouldShowSource: Bool {
        prefs.captionDisplayMode == .bilingual
    }
    private var typography: CaptionTypography {
        CaptionTypography(width: isCompact ? 392 : 560,
                          sourceSize: sourceFontSize, translationSize: translationFontSize,
                          showsSource: shouldShowSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            header

            captionContent
                .id(engine.captions.visible?.id)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: engine.captions.visible?.id)

            HStack {
                Text(engine.sessionNotice?.detail
                     ?? (engine.captions.visible?.isCorrection == true ? "Updated wording"
                         : engine.captions.visible?.isDraft == true ? "Live translation" : " "))
                Spacer()
                if let notice = engine.sessionNotice {
                    switch notice {
                    case .saved, .failed:
                        Button("View history") { TranscriptHistoryWindowPresenter.shared.show() }
                            .buttonStyle(.plain)
                    case .saving, .empty: EmptyView()
                    }
                } else if engine.droppedUtteranceCount > 0 {
                    Text("\(engine.droppedUtteranceCount) audio segments missed").foregroundStyle(.orange)
                } else if engine.captions.queuedCount > 0 {
                    Text("\(engine.captions.queuedCount) \(engine.captions.queuedCount == 1 ? "segment" : "segments") queued")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, isCompact ? 14 : 20)
        .padding(.vertical, isCompact ? 12 : 16)
        .frame(width: isCompact ? 420 : 600, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // A stable dark surface keeps captions legible over white
                // slides and bright meeting windows as well as dark video.
                .fill(Color(red: 0.055, green: 0.063, blue: 0.078).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
        // Leave enough slack on all sides for the drop shadow to fade out
        // naturally — less than (shadow radius + y offset) gets clipped by
        // the hosting window and produces a visible hard-edged rectangle
        // under the card.
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .onAppear { engine.captions.reflow(typography) }
        .onChange(of: typography) { _, value in engine.captions.reflow(value) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        // No animation on `translationText` — LLM streaming writes dozens
        // of updates per second; animating each one makes the whole line
        // look like it's being "re-printed" every token. Tokens should
        // just append instantly.
        // Source snapshots and status changes must not animate the caption
        // subtree either — that also animates translation reflow implicitly.
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()

            // Language chip / hover controls — share the same slot so the
            // card doesn't jiggle when the hover state flips.
            ZStack(alignment: .trailing) {
                Text("→ \(engine.targetLanguage)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 0 : 1)
                controlButtons
                    .opacity(isHovered ? 1 : 0)
            }
        }
    }

    // MARK: - Control buttons (hover-revealed)

    private var controlButtons: some View {
        HStack(spacing: 4) {
            ControlButton(
                systemImage: engine.phase == .listening ? "pause.fill" : "play.fill",
                help: engine.phase == .listening ? "End session" : "Start new session"
            ) {
                engine.toggle()
            }
            .disabled(engine.isCaptionPreview)

            ControlButton(systemImage: "gearshape", help: "Preferences") {
                PreferencesWindowPresenter.shared.show(engine: engine)
            }

            ControlButton(systemImage: "clock.arrow.circlepath", help: "Transcript history") {
                TranscriptHistoryWindowPresenter.shared.show()
            }

            ControlButton(systemImage: "doc.on.doc", help: "Copy visible subtitle") {
                copyCurrentTranslation()
            }
            .disabled(engine.captions.visible?.translation.raw.isEmpty ?? true)

            ControlButton(
                systemImage: "square.and.arrow.up",
                help: "Export current session"
            ) {
                TranscriptExportCoordinator.export(
                    entries: TranscriptHistory.shared.currentSession,
                    suggestedName: "ora-session-\(TranscriptExportCoordinator.timestamp())"
                )
            }

            ControlButton(systemImage: "xmark", help: "Hide window") {
                PanelManager.shared.hide()
            }
        }
    }

    private func copyCurrentTranslation() {
        guard let text = engine.captions.visible?.translation.raw, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Translation line

    @ViewBuilder
    private var captionContent: some View {
        let cue = engine.captions.visible
        let translation = cue?.translation.display ?? ""
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            if shouldShowSource {
                Text(cue?.source.display ?? "")
                    .font(Font(typography.sourceFont))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: lineHeight(typography.sourceFont) * 2, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(engine.sessionNotice?.title ?? (!translation.isEmpty ? translation
                 : cue != nil ? (cue?.isDraft == true ? "Translating…" : " ") : placeholderText))
                .font(Font(typography.translationFont))
                .foregroundStyle(!translation.isEmpty ? Color.primary : Color.secondary)
                .frame(minHeight: lineHeight(typography.translationFont) * 2, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    // MARK: - Status indicator

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        if let notice = engine.sessionNotice {
            switch notice {
            case .saving: return .orange
            case .saved: return .green
            case .empty: return .gray
            case .failed: return .pink
            }
        }
        switch engine.phase {
        case .listening: return .red
        case .ready: return .green
        case .loading: return .orange
        case .idle: return .gray
        case .error: return .pink
        }
    }

    private var statusLabel: String {
        if engine.isCaptionPreview { return "Caption preview" }
        if let notice = engine.sessionNotice {
            switch notice {
            case .saving: return "Saving"
            case .saved: return "Saved"
            case .empty: return "Session ended"
            case .failed: return "Save failed"
            }
        }
        switch engine.phase {
        case .idle: return "Idle"
        case .loading(let status, _): return status
        case .ready: return engine.captions.isDraining ? "Finishing captions" : "Ready"
        case .listening: return engine.isPartial ? "Live · Updating" : "Listening"
        case .error: return "Error"
        }
    }

    private var placeholderText: String {
        switch engine.phase {
        case .idle: return "Click the menu bar icon to begin"
        case .loading(let status, _): return status
        case .ready: return "Ready — speak to translate"
        case .listening: return "Listening…"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Small circular control button

private struct ControlButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isOver: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isOver ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { isOver = over }
        }
    }
}
