import SwiftUI

/// Cross-source matching ("换源") modal powered by `MusicMatcher.findOtherSourceMatches`.
struct SourceSwitchSheet: View {
    let targetTrack: MusicInfo
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayerController.self) private var player

    @State private var isLoading = true
    @State private var matches: [MusicInfo] = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在全网五大音源匹配「\(targetTrack.name)」...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if matches.isEmpty {
                    ContentUnavailableView(
                        "未找到匹配音源",
                        systemImage: "magnifyingglass",
                        description: Text("未能从其他平台匹配到相同的曲目")
                    )
                } else {
                    List {
                        Section("当前歌曲") {
                            trackSummaryRow(targetTrack, badge: "当前")
                        }

                        Section("匹配到的其他音源（按匹配度排序）") {
                            ForEach(matches) { candidate in
                                Button {
                                    if player.currentTrack?.id == targetTrack.id {
                                        player.switchToAlternativeTrack(candidate)
                                    } else {
                                        player.playAdHoc(tracks: [candidate], startIndex: 0)
                                    }
                                    env.showToast("已切换至 \(candidate.source.displayName)")
                                    dismiss()
                                } label: {
                                    trackSummaryRow(candidate, badge: candidate.highestQuality?.badgeText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("跨源换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                isLoading = true
                matches = await MusicMatcher.findOtherSourceMatches(for: targetTrack)
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func trackSummaryRow(_ track: MusicInfo, badge: String?) -> some View {
        HStack(spacing: 10) {
            Text(track.source.shortName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accentColor, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(track.singer)\(track.meta.albumName.isEmpty ? "" : " · \(track.meta.albumName)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let interval = track.interval, !interval.isEmpty {
                Text(interval)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accentColor)
            }
        }
    }
}
