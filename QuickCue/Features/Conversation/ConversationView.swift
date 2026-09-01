import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showRoleExplanation = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        statusHeader

                        if store.visibleConversationMessages.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.visibleConversationMessages) { message in
                                ConversationMessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if !store.conversationLiveTranscript.isEmpty {
                            liveTranscriptBubble
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 130)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: store.visibleConversationMessages.count) { _, _ in
                    if let id = store.visibleConversationMessages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Диалог")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRoleExplanation = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Как определяются говорящие")
                }
            }
            .safeAreaInset(edge: .bottom) { conversationControls }
            .alert("Определение говорящих", isPresented: $showRoleExplanation) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(store.speakerAttributionExplanation)
            }
            .alert("QuickCue", isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )) {
                Button("OK") { store.alertMessage = nil }
            } message: {
                Text(store.alertMessage ?? "")
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.isConversationListening ? Color.red : Color.secondary)
                .frame(width: 9, height: 9)
            Text(store.isConversationListening ? "Разговор записывается" : "Готов к разговору")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(settings.mockMode ? "Тест" : settings.providerTitle(for: settings.primaryProvider))
                .font(.caption.weight(.semibold))
                .foregroundStyle(settings.mockMode ? .orange : .green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background((settings.mockMode ? Color.orange : Color.green).opacity(0.1), in: Capsule())
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.08))
                    .frame(width: 150, height: 150)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.indigo)
            }
            Text("Начните разговор")
                .font(.title2.bold())
            Text("QuickCue покажет реплики собеседника, ваши ответы и подсказки AI как обычный чат.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            Button("Как определяются роли?") { showRoleExplanation = true }
                .font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var liveTranscriptBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("Сейчас слышу")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Text(store.conversationLiveTranscript)
                    .font(.body)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var conversationControls: some View {
        HStack(spacing: 32) {
            QuickCaptureButton(
                presentation: .conversation,
                includeInConversation: true
            )

            conversationControl(
                title: store.isConversationListening ? "Пауза" : "Слушать",
                systemImage: store.isConversationListening ? "mic.slash.fill" : "mic.fill",
                color: store.isConversationListening ? .red : .indigo,
                action: store.toggleConversationListening
            )

            conversationControl(
                title: "Завершить",
                systemImage: "power",
                color: .red,
                action: store.endConversation
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func conversationControl(
        title: String,
        systemImage: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 68, height: 68)
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationMessageBubble: View {
    @EnvironmentObject private var store: SessionStore
    @Bindable var message: ConversationMessageRecord

    private var speaker: ConversationSpeaker {
        ConversationSpeaker(rawValue: message.speakerRaw) ?? .assistant
    }

    private var kind: ConversationMessageKind {
        ConversationMessageKind(rawValue: message.kindRaw) ?? .speech
    }

    private var status: AnswerStatus {
        AnswerStatus(rawValue: message.statusRaw) ?? .completed
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            switch speaker {
            case .me:
                Spacer(minLength: 12)
                transferButton(to: .partner, systemImage: "arrow.left")
                bubbleContent
            case .partner:
                bubbleContent
                transferButton(to: .me, systemImage: "arrow.right")
                Spacer(minLength: 12)
            case .assistant:
                bubbleContent
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            speakerLabel

            if kind == .photo, let path = message.photoRelativePath {
                LocalConversationPhoto(relativePath: path)
            }

            if message.text.isEmpty, status != .failed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status == .queued ? "В очереди…" : "Готовлю подсказку…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(kind == .error ? .red : .primary)
            }

            if speaker != .assistant, kind == .speech {
                Button("Спросить AI") { store.requestAnswer(for: message) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: speaker == .assistant ? .infinity : 315, alignment: .leading)
        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            if speaker == .assistant {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.indigo.opacity(0.18))
            }
        }
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if speaker == .assistant {
            Label("QuickCue", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.indigo)
        } else {
            Label(
                speaker.title,
                systemImage: speaker == .me ? "person.fill" : "person.wave.2.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(speaker == .me ? .indigo : .secondary)
        }
    }

    private func transferButton(
        to target: ConversationSpeaker,
        systemImage: String
    ) -> some View {
        Button {
            withAnimation(.snappy) {
                store.setSpeaker(target, for: message)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.1), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Перенести реплику: \(target.title)")
        .accessibilityHint("Меняет автора этой фразы")
    }

    private var bubbleColor: Color {
        switch speaker {
        case .me: Color.indigo.opacity(0.1)
        case .partner: Color(uiColor: .secondarySystemBackground)
        case .assistant: Color.indigo.opacity(0.055)
        }
    }
}

private struct LocalConversationPhoto: View {
    let relativePath: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 130)
                    .overlay { ProgressView() }
            }
        }
        .task(id: relativePath) {
            guard let url = try? PhotoStore().url(for: relativePath) else { return }
            image = UIImage(contentsOfFile: url.path)
        }
    }
}
