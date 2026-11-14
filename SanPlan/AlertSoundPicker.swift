import AVFoundation
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

// Выбор звука сигнала, один на всё приложение: «Тренировка» (конец отдыха) и «Планы» (напоминания) подключают AlertSoundRow.
//
//   AlertSoundRow(title: "Звук конца отдыха", choice: sounds.rest, onSelect: sounds.setRest)
//
// где `sounds = AlertSoundSettings.shared` (@ObservedObject). Список: системный тон, встроенные тоны, «Свой файл…».
// Нажатие выбирает звук и проигрывает его.

/// Прослушивание без будильника.
@MainActor
final class AlertSoundPreview: ObservableObject {
    private var player: AVAudioPlayer?

    /// Играет выбранную ступень громкости; нет варианта — полный файл.
    func play(_ choice: AlertSoundChoice, percent: Int = 100) {
        stop()
        guard let name = AlertSoundLibrary.playableName(choice, percent: percent) else {
            if case .system = choice { AudioServicesPlaySystemSound(1005) }
            return
        }
        if case .custom = choice { play(AlertSoundLibrary.customURL(name)) }
        else if let url = AlertSoundLibrary.builtinURL(name) { play(url) }
    }

    private func play(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

/// Загрузка своего файла: копия в Library/Sounds, длиннее 30 секунд обрезается до 29.
enum AlertSoundImporter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func importFile(from source: URL) async throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard AlertSoundImport.isSupported(source.lastPathComponent) else {
            throw Failure(message: "Подходят файлы mp3, m4a, wav и caf.")
        }
        let asset = AVURLAsset(url: source)
        let seconds: Double
        do { seconds = try await asset.load(.duration).seconds } catch { throw Failure(message: "Файл не читается как звук.") }
        guard seconds.isFinite, seconds > 0 else { throw Failure(message: "Файл не читается как звук.") }
        let plan = AlertSoundImport.plan(duration: seconds)
        let name = AlertSoundImport.storedName(id: String(UUID().uuidString.prefix(8)), original: source.lastPathComponent, plan: plan)
        let directory = AlertSoundLibrary.customDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        switch plan {
        case .copy:
            try FileManager.default.copyItem(at: source, to: target)
        case .trim:
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw Failure(message: "Не удалось обрезать файл до 29 секунд.")
            }
            export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: AlertSoundChoice.importSeconds, preferredTimescale: 600))
            try await export.export(to: target, as: .m4a)
        }
        return name
    }

    /// Делает копию своего файла с усилением ступени тем же экспортом (`custom-<id>-v60.m4a`); для 100 % ничего не нужно.
    static func ensureVariant(of name: String, percent: Int) async {
        let percent = AlertSoundVolume.normalized(percent)
        guard percent < 100 else { return }
        let manager = FileManager.default
        let candidates = AlertSoundVolume.candidates(base: name, percent: percent).dropLast()
        if candidates.contains(where: { manager.fileExists(atPath: AlertSoundLibrary.customURL($0).path) }) { return }
        let target = AlertSoundLibrary.customURL(candidates.last ?? name)
        let asset = AVURLAsset(url: AlertSoundLibrary.customURL(name))
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(Float(percent) / 100, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        export.audioMix = mix
        try? await export.export(to: target, as: .m4a)
    }

    /// Удаляет файл и его варианты громкости.
    static func delete(_ name: String) {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let directory = AlertSoundLibrary.customDirectory()
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let fileStem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            if file == name || fileStem == stem || (fileStem.hasPrefix(stem + "-v") && AlertSoundVolume.isVariant(file)) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
}

/// Строка настроек: название, текущий звук и переход к списку.
public struct AlertSoundRow: View {
    let title: String
    let choice: AlertSoundChoice
    let onSelect: (AlertSoundChoice) -> Void
    let volume: Int
    let onVolume: ((Int) -> Void)?
    @State private var showing = false

    /// `onVolume == nil` — строка «Громкость сигнала» не показывается.
    public init(title: String, choice: AlertSoundChoice, onSelect: @escaping (AlertSoundChoice) -> Void, volume: Int = 100, onVolume: ((Int) -> Void)? = nil) {
        self.title = title
        self.choice = choice
        self.onSelect = onSelect
        self.volume = volume
        self.onVolume = onVolume
    }

    public var body: some View {
        Button { showing = true } label: {
            HStack {
                Text(title).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(AlertSoundSheet.name(of: AlertSoundLibrary.choiceIsPlayable(choice), requested: choice))
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                Image(systemName: "chevron.right").font(.footnote).foregroundColor(DS.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .sheet(isPresented: $showing) {
            AlertSoundSheet(title: title, choice: choice, onSelect: onSelect, volume: volume, onVolume: onVolume)
        }
    }
}

struct AlertSoundSheet: View {
    let title: String
    let choice: AlertSoundChoice
    let onSelect: (AlertSoundChoice) -> Void
    let onVolume: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = AlertSoundPreview()
    @State private var selected: AlertSoundChoice
    @State private var percent: Int
    @State private var importing = false
    @State private var message: String?

    init(title: String, choice: AlertSoundChoice, onSelect: @escaping (AlertSoundChoice) -> Void, volume: Int, onVolume: ((Int) -> Void)?) {
        self.title = title
        self.choice = choice
        self.onSelect = onSelect
        self.onVolume = onVolume
        _selected = State(initialValue: choice)
        _percent = State(initialValue: AlertSoundVolume.normalized(volume))
    }

    static func name(of playable: AlertSoundChoice, requested: AlertSoundChoice) -> String {
        switch playable {
        case .system: return requested == .system ? "Системный" : "Системный (файла нет)"
        case .builtin(let file): return AlertSoundLibrary.title(forBuiltin: file)
        case .custom: return "Свой файл"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.system, title: "Системный тон", detail: "звонит, пока не остановите")
                    ForEach(AlertSoundLibrary.builtinNames(), id: \.self) { file in
                        row(.builtin(file), title: AlertSoundLibrary.title(forBuiltin: file), detail: "играет до 30 секунд")
                    }
                    if case .custom(let file) = selected {
                        let present = FileManager.default.fileExists(atPath: AlertSoundLibrary.customURL(file).path)
                        row(selected, title: "Свой файл", detail: present ? "играет до 30 секунд" : "файла нет на этом устройстве")
                    }
                    Button { importing = true } label: {
                        Label("Свой файл…", systemImage: "folder")
                    }
                }
                if onVolume != nil { volumeSection }
                if let message {
                    Section { Text(message).font(.footnote).foregroundColor(DS.Colors.textSecondary) }
                }
                Section {
                    Text("Свой файл копируется на устройство; длиннее 30 секунд обрезается до 29. Если система не примет файл, прозвучит системный тон.")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { preview.stop(); dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                handleImport(result)
            }
            .onDisappear { preview.stop() }
        }
    }

    private func row(_ value: AlertSoundChoice, title: String, detail: String) -> some View {
        Button {
            selected = value
            onSelect(value)
            play(value)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(DS.Colors.textPrimary)
                    Text(detail).font(.caption).foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                if selected == value { Image(systemName: "checkmark").foregroundColor(DS.Colors.accent) }
            }
        }
        .buttonStyle(.plain)
    }

    private var isSystem: Bool { if case .system = selected { return true } else { return false } }

    private var volumeSection: some View {
        Section {
            Picker("Громкость сигнала", selection: Binding(get: { percent }, set: setVolume)) {
                ForEach(AlertSoundVolume.steps, id: \.self) { Text("\($0) %").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isSystem)
            if isSystem {
                Text("Громкость системного тона задаёт телефон.").font(.footnote).foregroundColor(DS.Colors.textSecondary)
            }
        } header: { Text("Громкость сигнала") }
    }

    private func setVolume(_ value: Int) {
        percent = value
        onVolume?(value)
        Task {
            if case .custom(let name) = selected { await AlertSoundImporter.ensureVariant(of: name, percent: value) }
            preview.play(selected, percent: value)
        }
    }

    private func play(_ value: AlertSoundChoice) {
        Task {
            if case .custom(let name) = value { await AlertSoundImporter.ensureVariant(of: name, percent: percent) }
            preview.play(value, percent: percent)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            do {
                let name = try await AlertSoundImporter.importFile(from: url)
                if case .custom(let old) = selected { AlertSoundImporter.delete(old) }
                let value = AlertSoundChoice.custom(name)
                selected = value
                onSelect(value)
                message = nil
                await AlertSoundImporter.ensureVariant(of: name, percent: percent)
                preview.play(value, percent: percent)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
