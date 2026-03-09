import SwiftUI
import AVKit

/// Unified media player bar for audio/video sessions in history.
/// Provides play/pause, seek slider, and time labels — consistent with `AudioPlayerBarView`.
struct MediaPlayerBarView: View {
    @Bindable var playerModel: VideoHistoryPlayerModel
    var title: String? = nil

    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(.quaternary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))

            Text(formatTime(currentTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { seekTo($0) }
                ),
                in: 0...max(duration, 0.01)
            )
            .controlSize(.small)

            Text(formatTime(duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 48)
        .background(.bar)
        .onAppear { startObserving() }
        .onChange(of: playerModel.player) { _, _ in startObserving() }
    }

    private func togglePlayback() {
        guard let player = playerModel.player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    private func seekTo(_ time: TimeInterval) {
        guard let player = playerModel.player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func startObserving() {
        guard let player = playerModel.player else { return }
        if let item = player.currentItem {
            let dur = CMTimeGetSeconds(item.asset.duration)
            if dur.isFinite && dur > 0 {
                duration = dur
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak playerModel] cmTime in
            guard let playerModel else { return }
            let t = CMTimeGetSeconds(cmTime)
            Task { @MainActor in
                currentTime = t
                isPlaying = playerModel.player?.rate != 0

                if let item = playerModel.player?.currentItem {
                    let dur = CMTimeGetSeconds(item.asset.duration)
                    if dur.isFinite && dur > 0 {
                        duration = dur
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
