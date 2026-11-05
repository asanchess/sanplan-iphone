import SwiftUI

public struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isPasswordRevealed: Bool = false
    @State private var passwordText: String = ""

    public init() {}

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
