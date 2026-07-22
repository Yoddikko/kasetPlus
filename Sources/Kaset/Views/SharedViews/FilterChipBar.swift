import SwiftUI

/// A horizontal bar of filter chips styled like the Library view.
/// Each chip is a capsule button; the selected chip is accent-colored.
struct FilterChipBar<Filter: FilterOption>: View where Filter: Identifiable, Filter: Hashable {
    let filters: [Filter]
    @Binding var selection: Filter
    var animation: Animation = .easeInOut(duration: 0.2)

    var body: some View {
        HStack(spacing: 8) {
            ForEach(self.filters) { filter in
                self.chip(filter)
            }
            Spacer()
        }
    }

    private func chip(_ filter: Filter) -> some View {
        let isSelected = self.selection == filter
        return Button {
            withAnimation(self.animation) {
                self.selection = filter
            }
        } label: {
            Text(filter.displayName)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Conformance protocol for filter types used in FilterChipBar.
protocol FilterOption {
    var displayName: String { get }
    var id: String { get }
}
