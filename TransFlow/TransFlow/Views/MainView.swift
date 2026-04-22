import SwiftUI
import Translation

/// Root view with NavigationSplitView providing a collapsible sidebar.
/// On first launch the sidebar is expanded so users can discover navigation;
/// subsequent launches remember the collapsed state.
///
/// The shared ViewModel is injected from app root so it survives sidebar navigation
/// (switching between Transcription / History / Settings) and can be reused by
/// other UI surfaces like the floating preview window.
///
/// The `.translationTask` lives here (not in `ContentView`) so the
/// `TranslationSession` stays alive across tab switches — otherwise
/// the Translation framework fatally asserts when the session is used
/// after its owning view disappears.
struct MainView: View {
    @Bindable var viewModel: TransFlowViewModel
    @Bindable var floatingPreviewManager: FloatingPreviewPanelManager
    @Bindable var settings: AppSettings

    @State private var selectedDestination: SidebarDestination = .transcription
    @State private var columnVisibility: NavigationSplitViewVisibility = Self.initialColumnVisibility
    @State private var pendingHistorySessionID: String?

    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        return hasLaunched ? .detailOnly : .doubleColumn
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selectedDestination)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .translationTask(viewModel.translationService.configuration) { session in
            await viewModel.translationService.handleSession(session)
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettings)) { _ in
            selectedDestination = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHistory)) { notification in
            pendingHistorySessionID = notification.userInfo?["sessionID"] as? String
            selectedDestination = .history
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedDestination {
        case .transcription:
            ContentView(
                viewModel: viewModel,
                floatingPreviewManager: floatingPreviewManager,
                settings: settings
            )
        case .videoTranscription:
            VideoTranscriptionView()
        case .history:
            HistoryView(initialSessionID: $pendingHistorySessionID)
        case .settings:
            SettingsView()
        }
    }
}
