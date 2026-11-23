import SwiftUI

/// Horizontal pill picker for switching between the 5 online music sources (`kw`, `kg`, `tx`, `wy`, `mg`).
struct SourcePickerBar: View {
    @Binding var selected: MusicSource
    let accentColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicSource.onlineSources) { source in
                    let isSelected = (source == selected)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selected = source
                        }
                    } label: {
                        Text(source.displayName)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? accentColor : Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

/// Horizontal pill picker including aggregated ("聚合") search scope.
struct SearchScopePickerBar: View {
    @Binding var selected: SearchSourceScope
    let accentColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchSourceScope.allCases) { scope in
                    let isSelected = (scope == selected)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selected = scope
                        }
                    } label: {
                        Text(scope.displayName)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? accentColor : Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
