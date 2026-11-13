import SwiftUI

public struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isPasswordRevealed: Bool = false
    @State private var passwordText: String = ""
    @State private var emailText: String = ""
    @State private var codeText: String = ""
    @State private var codeSent: Bool = false

    public init() {}

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, DS.Metrics.spacing16)
            .frame(height: DS.Metrics.pillHeight)
            .background(DS.Colors.surfaceRaised)
            .foregroundColor(DS.Colors.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2)
                    .stroke(DS.Colors.hairline, lineWidth: 1)
            )
    }

    /// Sign-in by a 6-digit code sent to the address; shown when the server has mail configured.
    @ViewBuilder private var emailSection: some View {
        if authService.status?.emailLogin == true {
            VStack(spacing: DS.Metrics.spacing12) {
                if !codeSent {
                    field("Почта", text: $emailText)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .accessibilityIdentifier("email-login-address")
                    PillButton(
                        "Получить код на почту",
                        icon: "envelope",
                        style: .secondary,
                        isLoading: authService.isAuthenticating,
                        isEnabled: emailText.contains("@")
                    ) {
                        Task { codeSent = await authService.requestEmailCode(emailText) }
                    }
                } else {
                    Text("Код отправлен на \(emailText.trimmingCharacters(in: .whitespaces)). Проверьте и «Спам».")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                    field("Код из письма", text: $codeText)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("email-login-code")
                        .onChange(of: codeText) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { codeText = digits }
                        }
                    PillButton(
                        "Войти",
                        style: .primary,
                        isLoading: authService.isAuthenticating,
                        isEnabled: codeText.count == 6
                    ) {
                        Task { await authService.verifyEmailCode(email: emailText, code: codeText) }
                    }
                    Button("Другая почта или новый код") {
                        codeSent = false
                        codeText = ""
                    }
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                }
            }
        }
    }

    public var body: some View {
        ZStack {
            DS.Colors.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: DS.Metrics.spacing16) {
                    Text("ARNA")
                        .font(.system(size: 48, weight: .light, design: .default))
                        .foregroundColor(DS.Colors.textPrimary)
                        .tracking(4)
                }

                Spacer()

                VStack(spacing: DS.Metrics.spacing16) {
                    if let error = authService.errorMessage {
                        ErrorBanner(message: error) {
                            authService.errorMessage = nil
                        }
                    }

                    PillButton(
                        "Войти через Google",
                        icon: "arrow.right.circle",
                        style: .primary,
                        isLoading: authService.isAuthenticating
                    ) {
                        Task {
                            await authService.signInWithGoogle()
                        }
                    }

                    emailSection

                    if isPasswordRevealed {
                        VStack(spacing: DS.Metrics.spacing12) {
                            SecureField("Пароль владельца", text: $passwordText)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.horizontal, DS.Metrics.spacing16)
                                .frame(height: DS.Metrics.pillHeight)
                                .background(DS.Colors.surfaceRaised)
                                .foregroundColor(DS.Colors.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2)
                                        .stroke(DS.Colors.hairline, lineWidth: 1)
                                )

                            PillButton(
                                "Войти по паролю",
                                style: .secondary,
                                isLoading: authService.isAuthenticating,
                                isEnabled: !passwordText.isEmpty
                            ) {
                                Task {
                                    await authService.signInWithPassword(passwordText)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPasswordRevealed = true
                            }
                        }) {
                            Text("Вход для владельца")
                                .font(.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(height: DS.Metrics.minHitTarget)
                        }
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.bottom, DS.Metrics.spacing32)
            }
        }
    }
}
