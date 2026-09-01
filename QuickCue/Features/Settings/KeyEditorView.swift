import PhotosUI
import SwiftUI
import UIKit

struct KeyEditorView: View {
    let title: String
    let keychainAccount: String

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var errorMessage: String?
    @State private var scanMessage: String?
    @State private var isScanning = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(
                        hasStoredKey ? "Новый ключ (старый скрыт)" : "API-ключ",
                        text: $key
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if hasStoredKey {
                        Label("Ключ сохранён в Keychain этого iPhone", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }

                    if let scanMessage {
                        Label(scanMessage, systemImage: "text.viewfinder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Ключ")
                } footer: {
                    Text("Проверьте распознанный ключ перед сохранением: на фото похожими могут выглядеть 0/O, 1/l/I и дефисы.")
                }

                Section {
                    Button {
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            errorMessage = "Камера недоступна на этом устройстве."
                            return
                        }
                        showCamera = true
                    } label: {
                        Label("Сфотографировать ключ", systemImage: "camera.viewfinder")
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Выбрать готовое фото", systemImage: "photo")
                    }

                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Распознаю только на iPhone…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Добавить по фото")
                } footer: {
                    Text("Распознавание выполняется локально через Apple Vision. Фото ключа не сохраняется в истории QuickCue.")
                }

                if hasStoredKey {
                    Section {
                        Button("Удалить сохранённый ключ", role: .destructive) {
                            do {
                                try keychain.delete(account: keychainAccount)
                                hasStoredKey = false
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { refreshStoredState() }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await scan(item: item) }
            }
            .sheet(isPresented: $showCamera) {
                SecretCameraPicker { jpeg in
                    showCamera = false
                    Task { await scan(jpeg: jpeg) }
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .alert("API-ключ", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            try keychain.save(value, account: keychainAccount)
            key = ""
            hasStoredKey = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshStoredState() {
        do {
            hasStoredKey = try keychain.read(account: keychainAccount) != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scan(item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SecretScanError.unreadableImage
            }
            await scan(jpeg: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        selectedPhoto = nil
    }

    private func scan(jpeg: Data) async {
        isScanning = true
        defer { isScanning = false }
        do {
            let text = try await TextRecognizer().recognizeSecret(jpeg: jpeg)
            guard let candidate = SecretCandidateExtractor.bestCandidate(in: text) else {
                throw SecretScanError.noCandidate
            }
            key = candidate
            scanMessage = "Найден ключ: \(masked(candidate)). Нажмите «Сохранить»."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func masked(_ value: String) -> String {
        guard value.count > 10 else { return "••••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }
}

private enum SecretScanError: LocalizedError {
    case unreadableImage
    case noCandidate

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Не удалось прочитать выбранное изображение."
        case .noCandidate: "На фото не найден длинный API-ключ. Снимите ближе, без бликов, чтобы вся строка попала в кадр."
        }
    }
}

private struct SecretCameraPicker: UIViewControllerRepresentable {
    let onJPEG: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onJPEG: onJPEG, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onJPEG: (Data) -> Void
        let onCancel: () -> Void

        init(onJPEG: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onJPEG = onJPEG
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92) else {
                onCancel()
                return
            }
            onJPEG(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
