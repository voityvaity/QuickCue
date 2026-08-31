import SwiftData
import SwiftUI

struct CameraModeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var store: SessionStore
    @StateObject private var camera = CameraService()
    @StateObject private var remote = BLERemoteCaptureController()
    @State private var isProcessing = false
    @State private var recognizedText = ""
    @State private var errorMessage: String?
    @State private var previewData: Data?

    private let photoStore = PhotoStore()
    private let textRecognizer = TextRecognizer()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 14) {
                    if isProcessing {
                        HStack { ProgressView(); Text("Распознаю задачу и готовлю ответ…") }
                            .padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else if !recognizedText.isEmpty {
                        Text(recognizedText)
                            .font(.caption)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button { capture(source: .screenButton) } label: {
                        ZStack {
                            Circle().fill(.white).frame(width: 76, height: 76)
                            Circle().stroke(.black.opacity(0.25), lineWidth: 3).frame(width: 66, height: 66)
                            Image(systemName: "camera.fill").font(.title).foregroundStyle(.black)
                        }
                    }
                    .disabled(isProcessing || !camera.isConfigured)
                    .accessibilityLabel("Сфотографировать задачу")
                }
                .padding()
            }
            .navigationTitle("Фото-задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(remote.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .task {
                await camera.configure()
                remote.onCapture = { source in capture(source: source) }
                remote.start()
            }
            .onDisappear { camera.stop(); remote.stop() }
            .alert("Камера", isPresented: Binding(
                get: { errorMessage != nil || camera.lastError != nil },
                set: { if !$0 { errorMessage = nil; camera.lastError = nil } }
            )) {
                Button("OK") { errorMessage = nil; camera.lastError = nil }
            } message: {
                Text(errorMessage ?? camera.lastError ?? "")
            }
        }
    }

    private func capture(source: CaptureTriggerSource) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            do {
                let jpeg = try await camera.capture()
                previewData = jpeg
                let text = try await textRecognizer.recognize(jpeg: jpeg)
                recognizedText = text
                let sessionID = store.registerPhoto()
                let path = try photoStore.saveJPEG(jpeg)
                let photo = PhotoRecord(sessionID: sessionID, relativePath: path, recognizedText: text)
                modelContext.insert(photo)
                if let answer = await store.answerPhoto(jpeg: jpeg, recognizedText: text) {
                    photo.answerID = answer.id
                    photo.sessionID = answer.sessionID
                }
                try modelContext.save()
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
            _ = source
        }
    }
}
