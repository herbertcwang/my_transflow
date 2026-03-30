import Foundation

@MainActor
enum SpeechRuntimeRecovery {
    static func refreshSpeechModelState(for locale: Locale) async {
        let manager = SpeechModelManager.shared
        await manager.checkCurrentStatus(for: locale)
        await manager.refreshAllStatuses()
    }
}
