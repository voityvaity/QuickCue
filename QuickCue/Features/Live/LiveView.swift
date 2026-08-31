import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var manualQuestion = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    statusPanel
                    manualPanel
                    ForEach(store.visibleAnswers) { answer in
                        AnswerCardView(answer: answer)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("QuickCue")
            .toolbar {
                if store.currentSession != nil {
                    Button("Завершить") { store.endSession() }
                }
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

    private var statusPanel: some View {
        VStack(spacing: 18) {
            HStack {
                Circle()
                    .fill(store.isListening ? .red : .secondary)
                    .frame(width: 10, height: 10)
                Text(store.isListening ? "Слушаю русскую речь" : "Микрофон выключен")
                    .font(.headline)
                Spacer()
                Text(settings.mockMode ? "MOCK" : "LIVE")
                    .font(.caption.bold())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(settings.mockMode ? Color.orange.opacity(0.15) : Color.green.opacity(0.15), in: Capsule())
            }

            Text(store.liveTranscript.isEmpty ? "Здесь появится потоковая расшифровка…" : store.liveTranscript)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                .foregroundStyle(store.liveTranscript.isEmpty ? .secondary : .primary)
                .contentTransition(.numericText())

            Button(action: store.toggleListening) {
                Label(store.isListening ? "Остановить" : "Начать слушать", systemImage: store.isListening ? "stop.fill" : "mic.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isListening ? .red : .indigo)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var manualPanel: some View {
        HStack(spacing: 10) {
            TextField("Проверить вопрос вручную", text: $manualQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button {
                let value = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                store.submitManualQuestion(value)
                manualQuestion = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
