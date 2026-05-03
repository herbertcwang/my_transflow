import SwiftUI
import Carbon.HIToolbox

/// Simplified Settings page — only essentials for bilingual EN/ZH transcription via Apple Speech.
/// Sections: General, Hotkeys, Speech Models (EN-US + ZH-Hans), Feedback, About.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    private var updateChecker: UpdateChecker { UpdateChecker.shared }
    private var speechModelManager: SpeechModelManager { SpeechModelManager.shared }
    @State private var hotkeyManager = GlobalHotkeyManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ── General Section ──
                settingsSection(
                    header: "settings.general",
                    icon: "gearshape.fill",
                    iconColor: .gray
                ) {
                    appearanceRow
                }

                // ── Hotkeys Section ──
                settingsSection(
                    header: "settings.hotkeys",
                    icon: "keyboard.fill",
                    iconColor: .orange
                ) {
                    hotkeyAccessibilityHintRow

                    hotkeyRow(
                        label: "settings.hotkey.toggle_transcription",
                        icon: "waveform",
                        iconColor: .red,
                        binding: $settings.hotkeyToggleTranscription
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_translation",
                        icon: "translate",
                        iconColor: .blue,
                        binding: $settings.hotkeyToggleTranslation
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_floating_preview",
                        icon: "rectangle.dock",
                        iconColor: .purple,
                        binding: $settings.hotkeyToggleFloatingPreview
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_main_window",
                        icon: "macwindow",
                        iconColor: .green,
                        binding: $settings.hotkeyToggleMainWindow
                    )
                }

                // ── Speech Recognition Models Section (Apple Speech EN-US + ZH-Hans) ──
                settingsSection(
                    header: "settings.speech_models",
                    icon: "waveform.badge.mic",
                    iconColor: .indigo
                ) {
                    modelStatusRow(locale: "en-US", labelKey: "settings.model_en")
                    Divider().padding(.leading, 46)
                    modelStatusRow(locale: "zh-Hans", labelKey: "settings.model_zh")
                    Divider().padding(.leading, 46)
                    downloadAllButton
                }

                // ── Feedback Section ──
                settingsSection(
                    header: "settings.feedback",
                    icon: "bubble.left.fill",
                    iconColor: .blue
                ) {
                    feedbackRow
                    Divider().padding(.leading, 46)
                    openLogsRow
                }

                // ── About Section ──
                settingsSection(
                    header: "settings.about",
                    icon: "info.circle.fill",
                    iconColor: .secondary
                ) {
                    versionRow
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: "initial-load") {
            await speechModelManager.checkBilingualStatus()
        }
        .onAppear {
            Task {
                await speechModelManager.checkBilingualStatus()
            }
        }
        .onAppear {
            updateChecker.checkOnceOnLaunch()
        }
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(
        header: LocalizedStringKey,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.bottom, 8)
            .padding(.top, 20)

            // Content card
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            )
        }
    }

    // MARK: - General Content

    private var appearanceRow: some View {
        HStack(spacing: 8) {
            Label {
                Text("settings.appearance")
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: "moon.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.indigo)
                    .frame(width: 24)
            }

            Spacer()

            Picker("", selection: $settings.appAppearance) {
                Text("appearance.system").tag(AppAppearance.system)
                Text("appearance.light").tag(AppAppearance.light)
                Text("appearance.dark").tag(AppAppearance.dark)
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Apple Speech Model Rows (EN-US & ZH-Hans)

    /// A reusable row showing model status for a given locale with a download button.
    private func modelStatusRow(locale: String, labelKey: LocalizedStringKey) -> some View {
        let status = speechModelManager.localeStatuses[locale] ?? .checking

        return HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(labelKey)
                        .font(.system(size: 13, weight: .regular))
                    Text(modelStatusDescription(for: status))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(modelStatusColor(for: status))
                }
            } icon: {
                modelStatusIcon(for: status)
                    .frame(width: 24)
            }

            Spacer()

            modelStatusAction(for: locale, status: status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelStatusIcon(for status: SpeechModelStatus) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .unsupported:
            Image(systemName: "xmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red)
        }
    }

    private func modelStatusDescription(for status: SpeechModelStatus) -> LocalizedStringKey {
        switch status {
        case .installed: "model_status.installed"
        case .notDownloaded: "model_status.not_downloaded"
        case .downloading(let progress): "model_status.downloading_percent \(Int(progress * 100))"
        case .failed(let message): LocalizedStringKey("model_status.failed_detail \(message)")
        case .checking: "model_status.checking"
        case .unsupported: "model_status.unsupported"
        }
    }

    private func modelStatusColor(for status: SpeechModelStatus) -> Color {
        switch status {
        case .installed: .green
        case .notDownloaded: .secondary
        case .downloading: .blue
        case .failed: .orange
        case .checking: .secondary
        case .unsupported: .red
        }
    }

    @ViewBuilder
    private func modelStatusAction(for locale: String, status: SpeechModelStatus) -> some View {
        switch status {
        case .notDownloaded, .failed:
            Button {
                Task {
                    await speechModelManager.downloadModel(for: Locale(identifier: locale))
                }
            } label: {
                Text("model_action.select")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)

        case .downloading(let progress):
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 60)
                .tint(.blue)

        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("model_status.ready")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )

        case .checking, .unsupported:
            EmptyView()
        }
    }

    /// "Download All" button — appears only if either model is not installed.
    @ViewBuilder
    private var downloadAllButton: some View {
        let enStatus = speechModelManager.localeStatuses["en-US"] ?? .checking
        let zhStatus = speechModelManager.localeStatuses["zh-Hans"] ?? .checking
        let anyMissing: Bool = {
            switch (enStatus, zhStatus) {
            case (.installed, .installed): return false
            case (.checking, _), (_, .checking): return false
            default: return true
            }
        }()

        if anyMissing {
            HStack {
                Spacer()
                Button {
                    Task {
                        await speechModelManager.ensureBilingualModelsReady()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 12))
                        Text("settings.download_all_models")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                Spacer()
            }
        }
    }

    // MARK: - Feedback

    private var feedbackRow: some View {
        Button {
            openFeedback()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.feedback_title")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                        Text("settings.feedback_description")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Version Row

    private var versionRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.version")
                        .font(.system(size: 13, weight: .regular))
                    Text(appVersionString)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: "number.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            Spacer()

            if updateChecker.updateAvailable {
                Button {
                    if let url = updateChecker.updateURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("update_checker.update_available")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
            } else if updateChecker.isChecking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.6.2"
    }

    // MARK: - Open Logs Row

    private var openLogsRow: some View {
        Button {
            ErrorLogger.shared.openLogsFolder()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.open_logs")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                        Text("settings.open_logs_description")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }

                Spacer()

                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hotkey Accessibility Hint

    @ViewBuilder
    private var hotkeyAccessibilityHintRow: some View {
        if hotkeyManager.isAccessibilityGranted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                Text("settings.hotkey.accessibility_granted")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.leading, 46)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                Text("settings.hotkey.accessibility_hint")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Button {
                    hotkeyManager.requestAccessibility()
                } label: {
                    Text("settings.hotkey.grant_access")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("settings.hotkey.open_accessibility")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.leading, 46)
        }
    }

    // MARK: - Hotkey Row

    private func hotkeyRow(
        label: LocalizedStringKey,
        icon: String,
        iconColor: Color,
        binding: Binding<HotkeyBinding>
    ) -> some View {
        HStack {
            Label {
                Text(label)
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
            }

            Spacer()

            HotkeyRecorderView(binding: binding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openFeedback() {
        if let url = URL(string: "https://github.com/Cyronlee/TransFlow/issues") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if !binding.isEmpty {
                Button {
                    binding = .empty
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(displayText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRecording ? .white : (binding.isEmpty ? .secondary : .primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isRecording
                                  ? AnyShapeStyle(Color.accentColor)
                                  : AnyShapeStyle(.quaternary.opacity(0.5)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isRecording ? Color.accentColor : .clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode

            if keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if modifiers.isEmpty { return nil }

            binding = HotkeyBinding(
                keyCode: keyCode,
                modifiers: modifiers.rawValue
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private var displayText: String {
        if isRecording {
            return String(localized: "settings.hotkey.recording")
        }
        if binding.isEmpty {
            return String(localized: "settings.hotkey.not_set")
        }
        return binding.displayString
    }
}