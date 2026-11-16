import SwiftUI

/// Picks an exercise from the library or takes the typed name as a new one.
/// Оформление — «Тушь» (DESIGN-INK 11.6): поле поиска в рамке 2 pt, строки по 52 pt с разделителем.
struct ExerciseLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Найти или ввести своё", text: $query)
                    .inkText(.body)
                    .foregroundColor(Ink.Colors.fg)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .padding(.horizontal, Ink.Metrics.framePadding)
                    .frame(minHeight: Ink.Metrics.minHit)
                    .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
                    .padding(Ink.Metrics.page)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !typed.isEmpty && !ExerciseLibrary.allExercises.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
                            Button {
                                pick(typed)
                            } label: {
                                Label("Добавить «\(typed)»", systemImage: "plus.circle.fill")
                                    .inkText(.headline, weight: .bold)
                                    .foregroundColor(Ink.Colors.accentText)
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            InkRule()
                        }
                        ForEach(ExerciseLibrary.search(query)) { group in
                            Text(group.title)
                                .inkText(.subheadline, weight: .bold)
                                .foregroundColor(Ink.Colors.muted)
                                .padding(.top, Ink.Metrics.framePadding)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.exercises, id: \.self) { name in
                                Button {
                                    pick(name)
                                } label: {
                                    Text(name)
                                        .inkText(.headline, weight: .bold)
                                        .foregroundColor(Ink.Colors.fg)
                                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                InkRule()
                            }
                        }
                    }
                    .padding(.horizontal, Ink.Metrics.page)
                    .padding(.bottom, Ink.Metrics.stack)
                }
            }
            .background(Ink.Colors.bg.ignoresSafeArea())
            .navigationTitle("Упражнение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .tint(Ink.Colors.accentText)
    }

    private func pick(_ name: String) {
        onPick(name)
        dismiss()
    }
}
