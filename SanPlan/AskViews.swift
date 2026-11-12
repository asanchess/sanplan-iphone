import SwiftUI

/// Offer under the «+» field: when the text is a question the app can answer from its own data, one button gives the answer.
/// Nothing is sent anywhere and nothing is saved; the text stays in the field.
struct AskOffer: View {
    let text: String
    let data: () -> AskData
    @State private var answer: AskAnswer?

    var body: some View {
        if AskParser.looksLikeQuestion(text) {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                HeaderTextButton("Ответить на вопрос", icon: "questionmark.bubble") {
                    answer = AskEngine.answer(text, data: data())
                }
                if let answer {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                        Text(answer.text).font(.body).foregroundColor(DS.Colors.textPrimary)
                        ForEach(answer.lines, id: \.self) { line in
                            Text(line).font(.subheadline).foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    .padding(DS.Metrics.spacing12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                    .accessibilityElement(children: .combine)
                }
            }
            .onChange(of: text) { _, _ in answer = nil }
        }
    }
}
