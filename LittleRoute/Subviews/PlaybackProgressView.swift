import SwiftUI

struct PlaybackProgressView: View {
    let audioManager: AudioPlayerManager
    @State private var isSeeking = false
    @State private var proposedTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { isSeeking ? proposedTime : min(audioManager.currentTime, max(0.1, audioManager.songLength)) },
                set: { proposedTime = $0 }
            ), in: 0...max(0.1, audioManager.songLength)) { editing in
                if editing { proposedTime = audioManager.currentTime }
                else { audioManager.seek(to: proposedTime) }
                isSeeking = editing
            }
            .disabled(audioManager.songLength <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier("playbackPosition")
            HStack {
                Text(Duration.seconds(isSeeking ? proposedTime : audioManager.currentTime).formatted(.time(pattern: .minuteSecond)))
                Spacer()
                Text(Duration.seconds(audioManager.songLength).formatted(.time(pattern: .minuteSecond)))
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.top, 12)
        .onChange(of: audioManager.currentSong?.songName) { _, _ in isSeeking = false }
    }
}
