import SwiftUI

struct SpeechBenchmarkView: View {
    @EnvironmentObject private var store: SessionStore
    @StateObject private var runner = SpeechBenchmarkRunner()

    var body: some View {
        List {
            Section {
                Text("QuickCue сохраняет результаты только на этом iPhone. Аудио не записывается в файл и не отправляется вашему AI-провайдеру.")
                Text("Apple сама определяет доступный путь Speech; этот экран не обещает полностью локальное распознавание.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Что измеряется")
            }

            Section {
                Picker("Условия", selection: $runner.condition) {
                    ForEach(SpeechTestCondition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                .disabled(!runner.samples.isEmpty)
                LabeledContent("Набор", value: "30 вопросов + 20 фраз")
                LabeledContent(
                    "Прогресс",
                    value: "\(runner.currentIndex) / \(SpeechEvaluationCatalog.cases.count)"
                )
            } header: {
                Text("Одинаковый контрольный набор")
            }

            if let item = runner.currentCase {
                Section {
                    Text(item.phrase)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if !runner.recognizedText.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Распознано").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                            Text(runner.recognizedText)
                        }
                    }
                    if runner.isRecording {
                        HStack { ProgressView(); Text("Говорите фразу целиком…") }
                        Button("Отменить текущую фразу", role: .cancel) { runner.cancelCurrent() }
                    } else {
                        Button {
                            runner.startCurrent()
                        } label: {
                            Label("Записать эту фразу", systemImage: "mic.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text(item.expectsQuestion ? "Произнесите вопрос" : "Произнесите обычную фразу")
                } footer: {
                    Text("После устойчивой паузы QuickCue запросит финальный результат автоматически. Не нажимайте кнопку во время речи.")
                }
            } else if let report = runner.savedReports.first {
                let summary = SpeechEvaluationSummary(report: report)
                Section {
                    Label("Контрольный прогон завершён", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    LabeledContent("Precision вопросов", value: percent(summary.precision))
                    LabeledContent("Recall вопросов", value: percent(summary.recall))
                    LabeledContent("Дубли", value: "\(summary.duplicateEvents)")
                    LabeledContent("Финализация p50", value: milliseconds(summary.finalizationP50Milliseconds))
                    LabeledContent("Финализация p95", value: milliseconds(summary.finalizationP95Milliseconds))
                    Button("Начать новый прогон") { runner.resetRun() }
                } header: {
                    Text("Результат · n=\(summary.sampleCount) · \(report.condition.title)")
                } footer: {
                    Text("Цели из плана — ориентиры, не гарантия. Результат относится только к указанным build, устройству и условиям.")
                }
            }

            if !runner.savedReports.isEmpty {
                Section {
                    ForEach(runner.savedReports) { report in
                        let summary = SpeechEvaluationSummary(report: report)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("QuickCue \(report.appVersion) (\(report.appBuild)) · \(report.condition.title)")
                                .font(.subheadline.weight(.semibold))
                            Text("n=\(summary.sampleCount) · p50 \(milliseconds(summary.finalizationP50Milliseconds)) · p95 \(milliseconds(summary.finalizationP95Milliseconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(report.deviceFamily) · \(report.operatingSystem) · \(report.engine)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Удалить сохранённые прогоны", role: .destructive) {
                        runner.clearSavedReports()
                    }
                } header: {
                    Text("Последние измерения")
                }
            }

            Section {
                Text("SpeechAnalyzer пока не включён. Сначала этот же набор нужно прогнать на iPhone 15 Pro Max, затем сравнить второй адаптер на тех же условиях. Замена API без такого сравнения ухудшила бы доказательность.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Проверка речи")
        .onAppear { store.stopAllListening() }
        .onDisappear { runner.cancelCurrent() }
        .alert("Распознавание речи", isPresented: Binding(
            get: { runner.errorMessage != nil },
            set: { if !$0 { runner.cancelCurrent() } }
        )) {
            Button("OK") { runner.cancelCurrent() }
        } message: {
            Text(runner.errorMessage ?? "")
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func milliseconds(_ value: Int?) -> String {
        value.map { "\($0) мс" } ?? "нет данных"
    }
}
