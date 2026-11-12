import SwiftUI
import UIKit

/// One button behind a swiped row.
struct FinanceSwipeAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
}

/// A row that slides left to show actions (the operations feed lives in a plain stack, not a List, so
/// `.swipeActions` is unavailable). Vertical drags scroll as usual; a horizontal one opens the actions
/// with a light tap. VoiceOver gets the same actions as custom actions.
struct FinanceSwipeRow<Content: View>: View {
    let actions: [FinanceSwipeAction]
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0

    private let buttonWidth: CGFloat = 76
    private var revealWidth: CGFloat { buttonWidth * CGFloat(actions.count) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        close()
                        if action.isDestructive {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } else {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        action.perform()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.systemImage)
                            Text(action.title).font(.caption2).lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .frame(width: buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(action.isDestructive ? DS.Colors.destructive : DS.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(offset == 0)
                }
            }
            .opacity(offset == 0 ? 0 : 1)

            content()
                .background(DS.Colors.surface)
                .offset(x: offset)
                .gesture(swipe)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { action.perform() }
            }
        }
    }

    private var swipe: HorizontalSwipe {
        HorizontalSwipe(
            onChanged: { dx in
                let base: CGFloat = offset <= -revealWidth ? -revealWidth : 0
                offset = min(0, max(-revealWidth - 24, base + dx))
            },
            onEnded: { dx, predicted in
                let wasOpen = offset <= -revealWidth / 2 && dx < 0 || (offset < 0 && predicted < -80)
                withAnimation(.easeOut(duration: 0.18)) { offset = wasOpen ? -revealWidth : 0 }
                if wasOpen { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
        )
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
    }
}

extension StatementImport {
    /// Category change from a swipe: everything else about the record stays as it is.
    public static func recategorize(_ id: String, to category: String, in state: FinanceState) throws -> FinanceState {
        guard let r = state.records.first(where: { $0.id == id }) else {
            throw FinanceError.invalidDraft("Запись не найдена")
        }
        let edit = RecordEdit(
            title: r.title, amountMinor: r.amountMinor ?? 0, date: r.date ?? "", category: category,
            note: r.note ?? "", excluded: r.excluded == true
        )
        return try Self.edit(id, edit, in: state)
    }
}
