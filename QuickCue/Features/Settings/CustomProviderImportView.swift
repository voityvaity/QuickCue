import PhotosUI
import SwiftUI
import Vision

struct CustomProviderImportView: View {
    let profileID: UUID
    let onImport: (CustomProviderProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var payload = ""
    @State private var preview: CustomProviderImportPreview?
    @State private var errorMessage: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isScanning = false
    @State private var inspectedPayload = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $payload)
                        .frame(minHeight: 150)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Проверить JSON") { inspect(payload) }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Прочитать QR с фото", systemImage: "qrcode.viewfinder")
                    }
                    if isScanning {
                        HStack { ProgressView(); Text("Читаю QR только на iPhone…") }
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Профиль сервиса")
                } footer: {
                    Text("Профиль содержит адрес, протокол и модель. API-ключи из профилей не принимаются и не экспортируются.")
                }

                if let preview {
                    Section("Перед сохранением") {
                        LabeledContent("Сервис", value: preview.profile.displayName)
                        LabeledContent("Владелец адреса", value: preview.origin)
                        LabeledContent("Протокол", value: preview.protocolTitle)
                        LabeledContent("Модель", value: preview.profile.modelName)
                        Text(preview.dataDisclosure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Использовать этот профиль") {
                            onImport(preview.profile)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Импорт настроек")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onChange(of: payload) { _, _ in
                if payload != inspectedPayload {
                    preview = nil
                    errorMessage = nil
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                isScanning = true
                Task { await scan(item) }
            }
        }
    }

    private func inspect(_ value: String) {
        do {
            preview = try CustomProviderProfileCodec.decode(value, profileID: profileID)
            inspectedPayload = value
            errorMessage = nil
        } catch {
            preview = nil
            inspectedPayload = ""
            errorMessage = error.localizedDescription
        }
    }

    private func scan(_ item: PhotosPickerItem) async {
        defer { isScanning = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20_000_000 else {
                throw CustomProviderProfileImportError.invalidDocument
            }
            try Task.checkCancellation()
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(data: data).perform([request])
            try Task.checkCancellation()
            guard let value = request.results?.compactMap(\.payloadStringValue).first else {
                throw CustomProviderProfileImportError.invalidDocument
            }
            payload = value
            inspect(value)
        } catch is CancellationError {
            return
        } catch {
            preview = nil
            errorMessage = "QR не прочитан или не содержит профиль QuickCue."
        }
    }
}
