import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Режим") {
                    Toggle("Mock — без сети и ключей", isOn: $settings.mockMode)
                    Picker("Основной провайдер", selection: $settings.primaryProvider) {
                        ForEach(ProviderKind.allCases.filter { $0 != .mock }) { Text($0.title).tag($0) }
                    }
                    Picker("Резервный провайдер", selection: $settings.fallbackProvider) {
                        ForEach(ProviderKind.allCases.filter { $0 != .mock }) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Запуск резерва", value: settings.fallbackDelaySeconds.formatted(.number.precision(.fractionLength(1))) + " с")
                        Slider(value: $settings.fallbackDelaySeconds, in: 0.8...3.0, step: 0.1)
                    }
                }

                Section("Провайдеры") {
                    ForEach(ProviderKind.allCases.filter { $0 != .mock }) { provider in
                        NavigationLink {
                            ProviderSettingsView(provider: provider)
                        } label: {
                            Label(provider.title, systemImage: "network")
                        }
                    }
                }

                Section("Yandex Cloud") {
                    TextField("Folder ID", text: $settings.yandexFolderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Для YandexGPT 5.1 Pro модель задаётся URI gpt://<folder-id>/yandexgpt/latest. Точное доступное имя можно изменить в карточке провайдера.")
                }

                Section("Мягкие лимиты") {
                    LabeledContent("Месячный бюджет") {
                        TextField("2000", value: $settings.monthlyBudgetRUB, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("₽")
                    }
                    Stepper("Вопросов за сессию: \(settings.sessionQuestionLimit)", value: $settings.sessionQuestionLimit, in: 10...500, step: 10)
                    Stepper("Фото за сессию: \(settings.sessionPhotoLimit)", value: $settings.sessionPhotoLimit, in: 5...100, step: 5)
                    Stepper("Контекст: \(settings.contextMinutes) мин", value: $settings.contextMinutes, in: 1...30)
                } footer: {
                    Text("Лимиты предупреждают, но не блокируют владельца. Стоимость остаётся оценочной, пока не настроены актуальные тарифы/серверная телеметрия.")
                }

                Section("Конфиденциальность") {
                    Label("Аудио не сохраняется", systemImage: "waveform.slash")
                    Label("Текст, ответы и фото — только локально", systemImage: "iphone.gen3")
                    Label("Работа только при открытом приложении", systemImage: "lock.open")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

private struct ProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    let provider: ProviderKind
    @State private var modelName = ""
    @State private var inputRate = 0.0
    @State private var outputRate = 0.0
    @State private var showKeyEditor = false

    var body: some View {
        Form {
            Section("Модель") {
                TextField("ID модели", text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Сохранить ID модели") { settings.setModelName(modelName, for: provider) }
            } footer: {
                Text("ID моделей и доступность меняются у провайдеров. Поле вынесено в настройки, чтобы не выпускать новую сборку ради смены модели.")
            }
            Section("Доступ") {
                Button("Открыть Keychain-настройку") { showKeyEditor = true }
            }
            Section("Оценка расходов") {
                LabeledContent("Ввод / 1 млн токенов") {
                    TextField("0", value: $inputRate, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
                    Text("₽")
                }
                LabeledContent("Вывод / 1 млн токенов") {
                    TextField("0", value: $outputRate, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
                    Text("₽")
                }
                Button("Сохранить тарифы") { settings.setRates(input: inputRate, output: outputRate, for: provider) }
            } footer: {
                Text("Введите актуальные тарифы провайдера в рублях. Нулевые значения означают: расходы считаются по токенам, но денежная оценка не вычисляется.")
            }
        }
        .navigationTitle(provider.title)
        .task {
            modelName = settings.modelName(for: provider)
            inputRate = settings.inputRateRUB(for: provider)
            outputRate = settings.outputRateRUB(for: provider)
        }
        .sheet(isPresented: $showKeyEditor) { KeyEditorView(provider: provider) }
    }
}
