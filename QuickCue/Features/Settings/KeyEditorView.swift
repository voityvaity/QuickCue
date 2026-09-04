import PhotosUI
import SwiftUI
import UIKit

struct KeyEditorView: View {
    let title: String
    let keychainAccount: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettings
    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var errorMessage: String?
    @State private var scanMessage: String?
    @State private var isScanning = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isKeyVisible = false
    @State private var candidates: [String] = []
    @State private var concealTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanGeneration = UUID()
    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if isKeyVisible {
                            TextField("API-ключ", text: $key, axis: .vertical)
                        } else {
                            SecureField(
                                hasStoredKey ? "Новый ключ (старый скрыт)" : "API-ключ",
                                text: $key
                            )
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !key.isEmpty {
                        HStack {
                            Text("\(key.count) символов").foregroundStyle(.secondary)
                            Spacer()
                            Button(isKeyVisible ? "Скрыть" : "Показать на 15 с") { toggleKeyVisibility() }
                        }
                        .font(.caption)
                    }

                    if hasStoredKey {
                        Label("Ключ сохранён в Keychain этого iPhone", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }

                    if let scanMessage {
                        Label(scanMessage, systemImage: "text.viewfinder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if candidates.count > 1 {
                        DisclosureGroup("Другие найденные варианты (\(candidates.count))") {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                                Button {
                                    key = candidate
                                    isKeyVisible = false
                                } label: {
                                    Text("\(index + 1). \(masked(candidate)) · \(candidate.count) символов")
                                        .font(.caption.monospaced())
                                }
                            }
                        }
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
                                ProviderConnectionStatusStore.keyChanged(account: keychainAccount, settings: settings)
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
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    isKeyVisible = false
                    concealTask?.cancel()
                    cancelScan()
                }
            }
            .onDisappear {
                cancelScan()
                concealTask?.cancel()
                key = ""
                candidates = []
                isKeyVisible = false
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                startScan(item: item)
            }
            .sheet(isPresented: $showCamera) {
                SecretCameraPicker { jpeg in
                    showCamera = false
                    startScan(jpeg: jpeg)
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
            ProviderConnectionStatusStore.keyChanged(account: keychainAccount, settings: settings)
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

    private func startScan(item: PhotosPickerItem) {
        cancelScan()
        let generation = scanGeneration
        isScanning = true
        scanTask = Task { await scan(item: item, generation: generation) }
    }

    private func startScan(jpeg: Data) {
        cancelScan()
        let generation = scanGeneration
        isScanning = true
        scanTask = Task { await scan(jpeg: jpeg, generation: generation) }
    }

    private func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func scan(item: PhotosPickerItem, generation: UUID) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SecretScanError.unreadableImage
            }
            guard !Task.isCancelled, generation == scanGeneration else { return }
            await scan(jpeg: data, generation: generation)
        } catch {
            guard !Task.isCancelled, generation == scanGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if generation == scanGeneration {
            selectedPhoto = nil
            isScanning = false
        }
    }

    private func scan(jpeg: Data, generation: UUID) async {
        defer { if generation == scanGeneration { isScanning = false } }
        do {
            let text = try await TextRecognizer().recognizeSecret(jpeg: jpeg)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            candidates = SecretCandidateExtractor.candidates(in: text)
            guard let candidate = candidates.first else {
                throw SecretScanError.noCandidate
            }
            key = candidate
            isKeyVisible = false
            scanMessage = "Найден ключ: \(masked(candidate)). Нажмите «Сохранить»."
        } catch {
            guard !Task.isCancelled, generation == scanGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func masked(_ value: String) -> String {
        guard value.count > 10 else { return "••••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    private func toggleKeyVisibility() {
        concealTask?.cancel()
        isKeyVisible.toggle()
        guard isKeyVisible else { return }
        concealTask = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            isKeyVisible = false
        }
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
