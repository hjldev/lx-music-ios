import SwiftUI

/// Root 5-tab navigation shell with floating MiniPlayerBar,
/// global modals (FullPlayer, Queue, AddToPlaylist, SourceSwitch), and toast notifications.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(UserApiStore.self) private var userApiStore
    @Environment(PlayerController.self) private var player

    @State private var selectedTab: Int = 0

    private let accentColor = Color(red: 77 / 255.0, green: 175 / 255.0, blue: 124 / 255.0)

    var body: some View {
        @Bindable var bindableEnv = env
        @Bindable var bindableUserApi = userApiStore

        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                SongListSquareView(accentColor: accentColor)
                    .tabItem {
                        Label("歌单", systemImage: "square.grid.2x2")
                    }
                    .tag(0)

                LeaderboardView(accentColor: accentColor)
                    .tabItem {
                        Label("排行榜", systemImage: "chart.bar.fill")
                    }
                    .tag(1)

                SearchView(accentColor: accentColor)
                    .tabItem {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .tag(2)

                MyListsView(accentColor: accentColor)
                    .tabItem {
                        Label("我的", systemImage: "music.note.list")
                    }
                    .tag(3)

                SettingsView(accentColor: accentColor)
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
                    .tag(4)
            }
            .tint(accentColor)

            // Floating MiniPlayerBar above the native TabBar
            if player.currentTrack != nil {
                MiniPlayerBar(accentColor: accentColor)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Status bar lyrics capsule pinned below Top Safe Area
            if settingsStore.settings.enableStatusBarLyric && player.currentTrack != nil {
                VStack {
                    StatusBarLyricBar(accentColor: accentColor)
                        .padding(.top, 4)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Transient toast banner at top
            if let toast = env.toastMessage {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.78), in: Capsule())
                        .shadow(radius: 8)
                        .padding(.top, settingsStore.settings.enableStatusBarLyric && player.currentTrack != nil ? 44 : 12)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: player.currentTrack != nil)
        .animation(.easeInOut(duration: 0.2), value: env.toastMessage)
        .sheet(isPresented: $bindableEnv.showFullPlayer) {
            FullPlayerView(accentColor: accentColor)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .sheet(isPresented: $bindableEnv.showPlayQueue) {
            PlayQueueSheet(accentColor: accentColor)
        }
        .sheet(isPresented: Binding(
            get: { env.trackPendingAddToPlaylist != nil },
            set: { if !$0 { env.trackPendingAddToPlaylist = nil } }
        )) {
            if let tracks = env.trackPendingAddToPlaylist {
                AddToPlaylistSheet(tracks: tracks)
            }
        }
        .alert(
            bindableUserApi.pendingUpdateAlert?.scriptName ?? "自定义音源更新提示",
            isPresented: Binding(
                get: { userApiStore.pendingUpdateAlert != nil },
                set: { if !$0 { userApiStore.pendingUpdateAlert = nil } }
            ),
            presenting: userApiStore.pendingUpdateAlert
        ) { alert in
            if let urlStr = alert.updateUrl, let url = URL(string: urlStr) {
                Link("前往更新", destination: url)
            }
            Button("知道了", role: .cancel) {}
        } message: { alert in
            Text(alert.log)
        }
    }
}
