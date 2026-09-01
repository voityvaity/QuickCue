import SwiftData
import SwiftUI
import UIKit

struct CameraModeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var store: SessionStore
    @StateObject private var camera = CameraService()
    @StateObject private var remote = BLERemoteCaptureController()
    @State private var isProcessing = false
    @State private var isSending = false
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
                        HStack { ProgressView(); Text("Фотографирую и распознаю текст…") }
                            .padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else {
                        Text("Расположите задачу в кадре. После снимка можно проверить текст.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Button { takePhoto(source: .screenButton) } label: {
                        ZStack {
                            Circle().fill(.white).frame(width: 82, height: 82)
                            Circle().stroke(.black.opacity(0.25), lineWidth: 3).frame(width: 70, height: 70)
                            if isProcessing {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "camera.fill").font(.title).foregroundStyle(.black)
                            }
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
                    if remote.status == "Кнопка подключена" {
                        Text(remote.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await camera.configure()
                remote.onCapture = { source in takePhoto(source: source) }
                remote.start()
            }
            .onDisappear { camera.stop(); remote.stop() }
            .fullScreenCover(isPresented: Binding(
                get: { previewData != nil },
                set: { if !$0 { previewData = nil } }
            )) {
                reviewScreen
            }
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

    private var reviewScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let previewData, let image = UIImage(data: previewData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Текст распознан", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        TextEditor(text: $recognizedText)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        Text("Исправьте текст, если камера распознала код или условие неточно.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Переснять") {
                            previewData = nil
                            recognizedText = ""
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button {
                            Task { await sendReviewedPhoto() }
                        } label: {
                            if isSending {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("Отправить", systemImage: "arrow.up.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending)
                        .frame(maxWidth: .infinity)
                    }

                    Label("Фото хранится только на этом iPhone", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Проверка снимка")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func takePhoto(source: CaptureTriggerSource) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            do {
                let jpeg = try await camera.capture()
                let text = try await textRecognizer.recognize(jpeg: jpeg)
                previewData = jpeg
                recognizedText = text
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
            _ = source
        }
    }

    private func sendReviewedPhoto() async {
        guard let previewData else { return }
        isSending = true
        do {
            let sessionID = store.registerPhoto()
            let path = try photoStore.saveJPEG(previewData)
            let photo = PhotoRecord(
                sessionID: sessionID,
                relativePath: path,
                recognizedText: recognizedText
            )
            modelContext.insert(photo)
            if let answer = await store.answerPhoto(jpeg: previewData, recognizedText: recognizedText) {
                photo.answerID = answer.id
                photo.sessionID = answer.sessionID
            }
            try modelContext.save()
            self.previewData = nil
            recognizedText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }
}
