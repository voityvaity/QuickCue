import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showRoleExplanation = false
    @State private var manualText = ""
    @State private var hasEndedConversation = false
    @State private var followsLatest = true
    @State private var hasUnseenAnswer = false

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

                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                            .onAppear {
                                followsLatest = true
                                hasUnseenAnswer = false
                            }
                            .onDisappear { followsLatest = false }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: store.visibleConversationMessages.count) { _, _ in
                    followLatestIfNeeded(proxy)
                }
                .onChange(of: store.conversationUpdateRevision) { _, _ in
                    followLatestIfNeeded(proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasUnseenAnswer {
                        Button {
                            withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                            followsLatest = true
                            hasUnseenAnswer = false
                        } label: {
                            Label("Новый ответ", systemImage: "arrow.down")
                                .font(.caption.weight(.bold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                        .accessibilityHint("Перейти к последней реплике")
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
            Text(store.isConversationListening ? "Слушаю разговор" : "Микрофон выключен")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if settings.mockMode {
                Text("Тест · без сети").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                ProviderConnectionBadge(selection: settings.primaryProvider, compact: true)
            }
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
            Text(hasEndedConversation ? "Разговор завершён" : "Начните разговор")
                .font(.title2.bold())
            Text(hasEndedConversation
                 ? "Реплики и ответы сохранены в Истории. Можно начать новый разговор или написать вопрос ниже."
                 : (settings.answerTriggerPolicy == .automatic
                    ? "QuickCue покажет реплики собеседника, ваши ответы и подсказки AI как обычный чат. Аудиозапись не сохраняется."
                    : "QuickCue сохранит реплики без автоматических запросов. Нажмите «Отправить AI» у нужной фразы. Аудиозапись не сохраняется."))
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
        VStack(spacing: 10) {
            Picker("Когда отвечать", selection: $settings.answerTriggerPolicy) {
                ForEach(AnswerTriggerPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            HStack(spacing: 8) {
                TextField("Написать вопрос AI", text: $manualText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(submitText)
                Button(action: submitText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Отправить текст AI")
            }
            .padding(.horizontal)

            if store.visibleConversationMessages.contains(where: {
                [AnswerStatus.queued.rawValue, AnswerStatus.thinking.rawValue, AnswerStatus.streaming.rawValue].contains($0.statusRaw)
            }) {
                Button("Остановить ответы AI") { store.cancelActiveRequests() }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 32)
            }

            HStack(spacing: 32) {
                QuickCaptureButton(presentation: .conversation, includeInConversation: true)
                conversationControl(
                    title: store.isConversationListening ? "Пауза" : "Слушать",
                    systemImage: store.isConversationListening ? "mic.slash.fill" : "mic.fill",
                    color: store.isConversationListening ? .red : .indigo
                ) {
                    hasEndedConversation = false
                    store.toggleConversationListening()
                }
                conversationControl(title: "Завершить", systemImage: "power", color: .red) {
                    store.endConversation()
                    hasEndedConversation = true
                }
                .disabled(store.currentSession == nil)
            }
            PhotoTransferDisclosure(compact: true)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func followLatestIfNeeded(_ proxy: ScrollViewProxy) {
        if followsLatest {
            withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        } else {
            hasUnseenAnswer = true
        }
    }

    private func submitText() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hasEndedConversation = false
        store.submitConversationText(text)
        manualText = ""
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
    @EnvironmentObject private var settings: AppSettings
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

            if message.text.isEmpty, status == .queued || status == .thinking || status == .streaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status == .queued ? "В очереди…" : "Готовлю подсказку…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.text.isEmpty ? (status == .cancelled ? "Ответ остановлен" : "Ответ не получен") : message.text)
                    .font(speaker == .assistant ? answerFont : .body)
                    .textSelection(.enabled)
                    .foregroundStyle(kind == .error ? .red : .primary)
            }

            if speaker != .assistant, kind == .speech {
                Button("Отправить AI") { store.requestAnswer(for: message) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
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

    private var answerFont: Font {
        switch settings.answerTextSize {
        case .compact: .callout
        case .standard: .body
        case .large: .title3
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
                .frame(width: 44, height: 44)
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
