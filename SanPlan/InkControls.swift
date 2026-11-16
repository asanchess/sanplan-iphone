import SwiftUI

// «Тушь»: элементы управления и показа (DESIGN-INK 7.3–7.11): переключатель, степпер, ячейка подхода, шкала,
// баннер, тост, плитка итога, плашка раздела, маскот-заглушка и звукоподражание. Логики здесь нет.

// MARK: - Плашка раздела

/// Чёрный прямоугольник по ширине текста, не длиннее четырёх слов («плашка от автора»).
struct InkSectionHeader: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text)
            .inkPoster(15, relativeTo: .footnote)
            .foregroundColor(inverted ? Ink.Colors.accent : Ink.Colors.bg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(inverted ? Ink.Colors.onAccent : Ink.Colors.fg)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Переключатель

/// «План / История»: две равные клетки в общей рамке 3 pt; выбранная залита `fg`. Роль для диктора — как у системного.
struct InkSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.title)
                        .inkText(.body, weight: .bold)
                        .foregroundColor(isSelected ? Ink.Colors.bg : Ink.Colors.fg)
                        .frame(maxWidth: .infinity, minHeight: Ink.Metrics.minHit)
                        .background(isSelected ? Ink.Colors.fg : Ink.Colors.bg)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if index < items.count - 1 {
                    Rectangle().fill(Ink.Colors.fg).frame(width: Ink.Metrics.frameLine)
                }
            }
        }
        // Разделители гибкие по высоте: без этого сегменты тянулись на всё свободное место экрана.
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.frameLine))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Степпер

/// «Вес   [−] 80 кг [+]»: подпись слева, справа три ячейки в рамке 2 pt. Те же параметры, что у `ValueStepperRow`.
struct InkStepper: View {
    let title: String
    let value: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    /// Если задано, нажатие на значение открывает ввод с клавиатуры; замыкание возвращает false для непринятого числа.
    var onEnter: ((String) -> Bool)? = nil
    var allowsDecimal = false

    @State private var entering = false
    @State private var typed = ""

    var body: some View {
        // Подпись переносится под степпер, если в строке тесно (крупный текст).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Ink.Metrics.gutter) {
                label
                control
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                control
            }
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .contain)
        .alert(title, isPresented: $entering) {
            TextField(title, text: $typed)
                .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
            Button("Готово") { _ = onEnter?(typed) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var label: some View {
        Text(title)
            .inkText(.subheadline, weight: .medium)
            .foregroundColor(Ink.Colors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var control: some View {
        HStack(spacing: 0) {
            stepCell("minus", label: "Меньше: \(title)", enabled: canDecrease, action: onDecrease)
            Rectangle().fill(Ink.Colors.fg).frame(width: Ink.Metrics.cellLine)
            valueCell
            Rectangle().fill(Ink.Colors.fg).frame(width: Ink.Metrics.cellLine)
            stepCell("plus", label: "Больше: \(title)", enabled: canIncrease, action: onIncrease)
        }
        .fixedSize(horizontal: true, vertical: true)
        .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
    }

    @ViewBuilder private var valueCell: some View {
        let text = Text(value)
            .inkText(.headline, weight: .bold, numeric: true)
            .foregroundColor(Ink.Colors.fg)
            .contentTransition(.numericText())
            .animation(.snappy, value: value)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minWidth: 72, minHeight: 48)
            .padding(.horizontal, 4)
        if onEnter != nil {
            Button {
                typed = ""
                entering = true
            } label: {
                text.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(value)")
            .accessibilityHint("Ввести число")
        } else {
            text
        }
    }

    private func stepCell(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(enabled ? Ink.Colors.fg : Ink.Colors.muted)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Ячейка подхода

/// Ячейка сетки подходов: вес и повторы двумя строками (отметка «сделано» снизу). Состояния по таблице 2.5:
/// сделано — заливка `fg`; сейчас — заливка `accent`; впереди — рамка; пропущено — пунктир и «—».
struct InkSetCell: View {
    let weight: String
    let reps: String
    let state: InkSetState
    let setNumber: Int
    let accessibilityText: String
    let onEdit: () -> Void
    let onToggle: () -> Void
    let toggleLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onEdit) {
                VStack(spacing: 0) {
                    Text(state == .skipped ? "—" : weight)
                        .inkText(.headline, weight: .bold, numeric: true)
                    Text(state == .skipped ? "" : reps)
                        .inkText(.subheadline, weight: .bold, numeric: true)
                }
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Подход \(setNumber): \(accessibilityText)\(state == .now ? ", сейчас" : "")")

            Rectangle().fill(ruleColor).frame(height: Ink.Metrics.ruleLine)

            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: state == .done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17, weight: .bold))
                    Text(state.word)
                        .inkText(.subheadline, weight: .bold)
                }
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, minHeight: Ink.Metrics.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toggleLabel)
        }
        .frame(minWidth: 64)
        .background(background)
        .overlay(
            Rectangle().strokeBorder(
                borderColor,
                style: StrokeStyle(lineWidth: Ink.Metrics.cellLine, dash: state == .skipped ? [6, 4] : [])
            )
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state)
    }

    private var textColor: Color {
        switch state {
        case .todo: return Ink.Colors.fg
        case .done: return Ink.Colors.bg
        case .now: return Ink.Colors.onAccent
        case .skipped: return Ink.Colors.muted
        }
    }

    private var background: Color {
        switch state {
        case .todo, .skipped: return Ink.Colors.bg
        case .done: return Ink.Colors.fg
        case .now: return Ink.Colors.accent
        }
    }

    private var borderColor: Color { state == .skipped ? Ink.Colors.muted : Ink.Colors.fg }
    private var ruleColor: Color { state == .skipped ? Ink.Colors.muted : (state == .todo ? Ink.Colors.fg : textColor) }
}

/// Ячейка «+ Подход»: пунктир 2 pt, значок и подпись; не меньше 44 pt по высоте.
struct InkAddCell: View {
    let title: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold))
                Text(title).inkText(.subheadline, weight: .bold)
            }
            .foregroundColor(isEnabled ? Ink.Colors.accentText : Ink.Colors.muted)
            .frame(maxWidth: .infinity, minHeight: 97)
            .overlay(
                Rectangle().strokeBorder(
                    isEnabled ? Ink.Colors.accentText : Ink.Colors.muted,
                    style: StrokeStyle(lineWidth: Ink.Metrics.cellLine, dash: [6, 4])
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Шкала

/// Прямая шкала 12 pt: рамка 2 pt, пустая часть `soft`, заполненная `accent`. На акцентном кадре — `onAccent`.
struct InkProgressBar: View {
    let fraction: Double
    var onAccent = false
    /// Засечки подходов: вертикальные линии 2 pt.
    var ticks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(onAccent ? Ink.Colors.onAccent.opacity(0.25) : Ink.Colors.soft)
                Rectangle()
                    .fill(onAccent ? Ink.Colors.onAccent : Ink.Colors.accent)
                    .frame(width: width * CGFloat(min(max(fraction, 0), 1)))
                if ticks > 1 {
                    ForEach(1..<ticks, id: \.self) { index in
                        Rectangle()
                            .fill(onAccent ? Ink.Colors.onAccent : Ink.Colors.fg)
                            .frame(width: Ink.Metrics.cellLine)
                            .offset(x: width * CGFloat(index) / CGFloat(ticks) - 1)
                    }
                }
            }
            .clipShape(Rectangle())
        }
        .frame(height: 12)
        .overlay(Rectangle().strokeBorder(onAccent ? Ink.Colors.onAccent : Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - Баннер и тост

/// Ошибка и предупреждение: кадр 3 pt, слева значок, справа крестик 44×44, если баннер закрываемый.
struct InkBanner: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        InkPanel {
            HStack(alignment: .top, spacing: Ink.Metrics.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Ink.Colors.fg)
                    .accessibilityHidden(true)
                Text(message)
                    .inkText(.body)
                    .foregroundColor(Ink.Colors.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Ink.Colors.fg)
                            .frame(width: Ink.Metrics.minHit, height: Ink.Metrics.minHit)
                    }
                    .accessibilityLabel("Закрыть")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// «Отменить»: плашка `.inverse` внизу, текст `bg`, справа кнопка с подчёркиванием.
struct InkToast: View {
    let label: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Ink.Metrics.framePadding) {
            Text(label)
                .inkText(.body)
                .foregroundColor(Ink.Colors.bg)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onUndo) {
                Text("Отменить")
                    .inkText(.body, weight: .bold)
                    .foregroundColor(Ink.Colors.bg)
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Ink.Colors.bg).frame(height: Ink.Metrics.ruleLine)
                    }
                    .frame(minHeight: Ink.Metrics.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Ink.Metrics.framePadding)
        .background(Ink.Colors.fg)
    }
}

// MARK: - Плитки итога

/// Кадр 2 pt: подпись 15 pt `muted`, значение плакатным 20 pt, одна строка, сжатие до 0,7.
struct InkStatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .inkText(.subheadline, weight: .medium)
                .foregroundColor(Ink.Colors.muted)
            Text(value)
                .inkPoster(20, relativeTo: .headline)
                .foregroundColor(Ink.Colors.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Metrics.framePadding)
        .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
        .accessibilityElement(children: .combine)
    }
}

/// Три плитки: в ряд, а от `accessibility1` — в столбец.
struct InkStatRow: View {
    let tiles: [(title: String, value: String)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if InkStatLayout.isStacked(typeSize) {
            VStack(spacing: Ink.Metrics.gutter) { content }
        } else {
            HStack(spacing: Ink.Metrics.gutter) { content }
        }
    }

    private var content: some View {
        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
            InkStatTile(title: tile.title, value: tile.value)
        }
    }
}

// MARK: - Маскот

enum InkMascotPose: Equatable { case sleepy, shrug, rest, ignite, victory }

/// Место маскота. Пока нет анимированного ассета, ничего не рисует и не занимает места (раздел 10 и 11.1).
/// Расставлено там, где его покажет спецификация: `sleepy` (план, пустая история), `shrug` (пустой день),
/// `rest` (кадр отдыха), `ignite` (отдых окончен), `victory` (итог).
struct InkMascotSlot: View {
    let pose: InkMascotPose
    var size: CGFloat = 56

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

// MARK: - Звукоподражание

/// Плакатные буквы с заливкой `spark` и обводкой `fg` 2 pt; наклон −8°. Рядом всегда прямая подпись; VoiceOver его не читает.
struct InkSfx: View {
    let word: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) / 8 * 2 * .pi
                Text(word)
                    .inkPoster(size)
                    .foregroundColor(Ink.Colors.fg)
                    .offset(x: cos(angle) * 2, y: sin(angle) * 2)
            }
            Text(word).inkPoster(size).foregroundColor(Ink.Colors.spark)
        }
        .fixedSize()
        .rotationEffect(.degrees(-8))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Показывает звукоподражание один раз при смене `trigger` (или при появлении, если `onAppear`):
/// пружина 0.6 → 1.0 за 250 мс, держится 900 мс, гаснет за 200 мс. «Уменьшение движения» — без пружины.
struct InkSfxFlash: View {
    let word: String
    var size: CGFloat = 36
    let trigger: AnyHashable
    var onAppear = false

    @State private var shown = false
    @State private var token = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if shown {
                InkSfx(word: word, size: size)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onChange(of: trigger) { _, _ in flash() }
        .onAppear { if onAppear { flash() } }
    }

    private func flash() {
        token += 1
        let mine = token
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.85)) { shown = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1150))
            guard mine == token else { return }
            withAnimation(.easeOut(duration: 0.2)) { shown = false }
        }
    }
}
