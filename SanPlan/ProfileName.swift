import Combine
import SwiftUI

/// The name the profile shows: the owner's nickname, or the part of the email before «@».
enum ProfileNickname {
    static let maxLength = 24

    /// Trimmed and cut to `maxLength`; "" means «not set».
    static func normalized(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The part of the email before «@», capitalised; the whole text when there is no «@».
    static func fallback(email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let name = String(email[..<at])
        return name.isEmpty ? email : name.prefix(1).uppercased() + name.dropFirst()
    }

    static func display(nickname: String, email: String) -> String {
        let name = normalized(nickname)
        return name.isEmpty ? fallback(email: email) : name
    }
}

/// The nickname of the signed-in account. Kept in the account's shared encrypted `settings` collection
/// (record `s-profile`, kind `profile`), so every device of the account shows the same name; newest edit wins.
/// Nothing is kept outside the account: sign-out detaches and clears it.
@MainActor
final class ProfileNameStore: ObservableObject {
    static let shared = ProfileNameStore()
    static let recordID = "s-profile"
    static let kind = "profile"

    @Published private(set) var nickname = ""

    private var collection: VaultCollection<SettingsPayload>?
    private var observer: AnyCancellable?

    init() {}

    /// The account's `settings` collection is open (AppModel.settingsVault).
    func attach(collection: VaultCollection<SettingsPayload>) {
        detach()
        self.collection = collection
        observer = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }

    func detach() {
        observer = nil
        collection = nil
        if !nickname.isEmpty { nickname = "" }
    }

    /// False until the account's encrypted settings are open; the name field waits for them.
    var canEdit: Bool { collection?.isAvailable == true }

    /// Saves the trimmed name (at most 24 characters); an empty one goes back to the name from the email.
    @discardableResult
    func setNickname(_ raw: String) -> Bool {
        let next = ProfileNickname.normalized(raw)
        guard let collection, collection.isAvailable else { return false }
        var payload = collection.item(Self.recordID)?.data ?? SettingsPayload(kind: Self.kind)
        payload.kind = Self.kind
        payload.nickname = next.isEmpty ? nil : next
        guard collection.put(Self.recordID, payload) != nil else { return false }
        nickname = next
        return true
    }

    private func reconcile() {
        guard let collection, collection.isAvailable else {
            if !nickname.isEmpty { nickname = "" }
            return
        }
        let record = collection.item(Self.recordID)?.data
        let stored = record?.kind == Self.kind ? ProfileNickname.normalized(record?.nickname ?? "") : ""
        if stored != nickname { nickname = stored }
    }
}

/// «Имя» in «Профиль → Аккаунт»: edits the nickname in place. Empty shows the name from the email as a hint.
struct ProfileNameRow: View {
    let email: String
    @ObservedObject private var names = ProfileNameStore.shared
    @Environment(\.sectionAccent) private var accent
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var placeholder: String {
        ScreenshotRoute.demoData ? "Алекс" : ProfileNickname.fallback(email: email)
    }

    var body: some View {
        ProfileRow("Имя", note: "Видно в профиле. Пусто — имя из почты") {
            TextField(placeholder, text: $draft)
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(accent)
                .tint(accent)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .frame(maxWidth: 170)
                .disabled(!names.canEdit)
                .accessibilityLabel("Имя")
                .accessibilityIdentifier("profile-nickname")
                .onSubmit { commit() }
        }
        .onAppear { draft = names.nickname }
        .onChange(of: draft) { _, value in
            if value.count > ProfileNickname.maxLength { draft = String(value.prefix(ProfileNickname.maxLength)) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: names.nickname) { _, value in
            if !focused { draft = value }
        }
        .onDisappear { if focused { commit() } }
    }

    private func commit() {
        if ProfileNickname.normalized(draft) != names.nickname { names.setNickname(draft) }
        draft = names.nickname
    }
}
