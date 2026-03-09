import Foundation
import SwiftUI

/// Type filter for the history list.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case live
    case media
    case video

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .all: "history.filter.all"
        case .live: "history.filter.live"
        case .media: "history.filter.audio"
        case .video: "history.filter.video"
        }
    }
}

/// Source type of a history item.
enum HistoryItemType {
    case live
    case video
    case audio
}

private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

/// Unified wrapper for live `SessionFile` and video `VideoSessionFile`.
struct HistoryItem: Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    let entryCount: Int
    let type: HistoryItemType

    /// Underlying live session (non-nil when `type == .live`).
    let liveSession: SessionFile?
    /// Underlying video session (non-nil when `type == .video` or `.audio`).
    let videoSession: VideoSessionFile?

    // MARK: - Convenience

    init(live session: SessionFile) {
        self.id = "live_\(session.id)"
        self.name = session.name
        self.createdAt = session.createdAt
        self.entryCount = session.entryCount
        self.type = .live
        self.liveSession = session
        self.videoSession = nil
    }

    init(video session: VideoSessionFile) {
        self.id = "video_\(session.id)"
        self.name = session.name
        self.createdAt = session.createdAt
        self.entryCount = session.entryCount

        let isActuallyVideo: Bool
        if let path = session.originalFilePath {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            isActuallyVideo = videoExtensions.contains(ext)
        } else if let file = session.videoFile {
            let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
            isActuallyVideo = videoExtensions.contains(ext)
        } else {
            isActuallyVideo = true
        }

        self.type = isActuallyVideo ? .video : .audio
        self.liveSession = nil
        self.videoSession = session
    }
}
