import SwiftUI

/// Content rendered inside the detachable floating preview panel.
struct FloatingPreviewView: View {
    @Bindable var viewModel: TransFlowViewModel
    @Bindable var panelManager: FloatingPreviewPanelManager
    @State private var isHovering = false
    @State private var showDisplaySettings = false

    private var settings: AppSettings { AppSettings.shared }

    private let captionBottomAnchor = "floating-caption-bottom"

    private static let fontSizeOptions: [CGFloat] = [
        12, 14, 16, 18, 20, 24, 28, 32, 36, 42, 48, 56, 64, 72
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            captionCard
            controlOverlay
        }
        .padding(2)
        .frame(minWidth: 340, idealWidth: 390, minHeight: 96, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .opacity(settings.floatingPanelOpacity)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }

    private var captionCard: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(captionLines) { line in
                        captionLineView(line)
                    }

                    Color.clear
                        .frame(height: 0)
                        .id(captionBottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .onAppear {
                scrollToBottom(with: proxy, animated: false)
            }
            .onChange(of: captionLines) { _, _ in
                scrollToBottom(with: proxy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var controlOverlay: some View {
        HStack(spacing: 6) {
            displaySettingsButton
            pinButton
            closeButton
        }
        .padding(.top, 4)
        .padding(.trailing, 8)
        .opacity(shouldShowControls ? 1 : 0)
        .allowsHitTesting(shouldShowControls)
        .zIndex(5)
    }

    private static let controlSize: CGFloat = 22

    private var pinButton: some View {
        Button {
            panelManager.togglePin()
        } label: {
            Image(systemName: panelManager.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(panelManager.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .help(Text(panelManager.isPinned ? "floating_preview.unpin" : "floating_preview.pin"))
        .accessibilityLabel(Text(panelManager.isPinned ? "floating_preview.unpin" : "floating_preview.pin"))
    }

    private var closeButton: some View {
        Button {
            panelManager.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .help(Text("floating_preview.close"))
        .accessibilityLabel(Text("floating_preview.close"))
    }

    private var displaySettingsButton: some View {
        Button {
            showDisplaySettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .help(Text("floating_preview.display_settings"))
        .accessibilityLabel(Text("floating_preview.display_settings"))
        .popover(isPresented: $showDisplaySettings, arrowEdge: .top) {
            displaySettingsPopover
        }
    }

    private var displaySettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("floating_preview.font_size")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Picker(selection: Binding(
                    get: {
                        Self.fontSizeOptions.min(by: {
                            abs($0 - settings.floatingPanelFontSize) < abs($1 - settings.floatingPanelFontSize)
                        }) ?? settings.floatingPanelFontSize
                    },
                    set: { settings.floatingPanelFontSize = $0 }
                )) {
                    ForEach(Self.fontSizeOptions, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .fixedSize()
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("floating_preview.opacity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(Int((settings.floatingPanelOpacity * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { settings.floatingPanelOpacity },
                        set: { settings.floatingPanelOpacity = $0 }
                    ),
                    in: AppSettings.minFloatingPanelOpacity...1.0
                )
                .controlSize(.small)
            }

            Divider()

            // Max entries picker
            HStack {
                Text("floating_preview.max_entries")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Picker(selection: Binding(
                    get: { settings.floatingPanelMaxEntries },
                    set: { settings.floatingPanelMaxEntries = $0 }
                )) {
                    ForEach(FloatingPanelMaxEntries.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .fixedSize()
                .labelsHidden()
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private var sourceFontSize: CGFloat {
        AppSettings.shared.floatingPanelFontSize
    }

    private var translationFontSize: CGFloat {
        AppSettings.shared.floatingPanelTranslationFontSize
    }

    @ViewBuilder
    private func captionLineView(_ line: CaptionLine) -> some View {
        let fontSize = line.kind == .source ? sourceFontSize : translationFontSize
        if line.isPartial {
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(lineForegroundStyle(for: line.kind))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(lineForegroundStyle(for: line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineForegroundStyle(for kind: CaptionLine.Kind) -> AnyShapeStyle {
        switch kind {
        case .source:
            AnyShapeStyle(.primary)
        case .translation:
            AnyShapeStyle(.secondary)
        case .placeholder:
            AnyShapeStyle(.tertiary)
        }
    }

    private var captionLines: [CaptionLine] {
        let showTranslation = viewModel.translationService.isEnabled
        var lines: [CaptionLine] = []

        let finalizedSentences: [TranscriptionSentence]
        if let limit = settings.floatingPanelMaxEntries.limit {
            finalizedSentences = Array(viewModel.sentences.suffix(limit))
        } else {
            finalizedSentences = viewModel.sentences
        }

        for sentence in finalizedSentences {
            let sourceText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceText.isEmpty {
                let prefix = sentence.speakerId.map { SpeakerDisplayName.displayName(for: $0) + ": " } ?? ""
                lines.append(
                    CaptionLine(
                        id: "sentence-source-\(sentence.id.uuidString)",
                        text: prefix + sourceText,
                        kind: .source
                    )
                )
            }

            if showTranslation,
               let translation = sentence.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty {
                lines.append(
                    CaptionLine(
                        id: "sentence-translation-\(sentence.id.uuidString)",
                        text: translation,
                        kind: .translation
                    )
                )
            }
        }

        let partialSource = viewModel.currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partialSource.isEmpty {
            lines.append(
                CaptionLine(
                    id: "partial-source",
                    text: partialSource,
                    kind: .source,
                    isPartial: true
                )
            )

            if showTranslation,
               let partialTranslationText,
               !partialTranslationText.isEmpty {
                lines.append(
                    CaptionLine(
                        id: "partial-translation",
                        text: partialTranslationText,
                        kind: .translation,
                        isPartial: true
                    )
                )
            }
        }

        if lines.isEmpty {
            let placeholderText = isListening
                ? String(localized: "control.listening")
                : String(localized: "control.start_transcription")
            lines.append(
                CaptionLine(
                    id: "placeholder",
                    text: placeholderText,
                    kind: .placeholder
                )
            )
        }

        return lines
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(captionBottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                action()
            }
        } else {
            action()
        }
    }

    private var isListening: Bool {
        viewModel.listeningState == .active || viewModel.listeningState == .starting
    }

    private var shouldShowControls: Bool {
        isHovering || panelManager.isPinned
    }

    private var partialTranslationText: String? {
        guard viewModel.translationService.isEnabled else { return nil }
        let partial = viewModel.translationService.currentPartialTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return partial.isEmpty ? nil : partial
    }
}

private struct CaptionLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case source
        case translation
        case placeholder
    }

    let id: String
    let text: String
    let kind: Kind
    var isPartial: Bool = false
}

