import SwiftUI

struct KeyEditorView: View {
    let provider: ProviderKind
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var errorMessage: String?
    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(hasStoredKey ? "Новый ключ (старый скрыт)" : "API-ключ", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if hasStoredKey {
                        Label("Ключ сохранён в Keychain этого iPhone", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                } footer: {
                    Text("Ключ хранится в защищённом хранилище этого iPhone и не попадает в файлы проекта.")
                }

                if hasStoredKey {
                    Button("Удалить сохранённый ключ", role: .destructive) {
                        do { try keychain.delete(account: provider.keychainAccount); hasStoredKey = false }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            .navigationTitle(provider.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do {
                            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            try keychain.save(value, account: provider.keychainAccount)
                            key = ""
                            hasStoredKey = true
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                do { hasStoredKey = try keychain.read(account: provider.keychainAccount) != nil }
                catch { errorMessage = error.localizedDescription }
            }
            .alert("API-ключ", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
