import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var delivery: DiagnosticsDeliveryController
    @State private var snapshot = DiagnosticsSnapshot(events: [], droppedEvents: 0, storedBytes: 0)
    @State private var export: DiagnosticsExport?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var confirmsRevoke = false
    @State private var showsScanner = false
    @State private var pairingCode = ""
    @State private var isPairing = false

    private let recorder = DiagnosticsRecorder.shared

    var body: some View {
        List {
            Section {
                LabeledContent("Событий", value: "\(snapshot.events.count)")
                LabeledContent("Размер", value: ByteCountFormatter.string(
                    fromByteCount: Int64(snapshot.storedBytes), countStyle: .file
                ))
                LabeledContent("Пропущено при нагрузке", value: "\(snapshot.droppedEvents)")
                LabeledContent("Хранение", value: "до 7 дней / 10 МБ")
            } header: {
                Text("Локальный журнал")
            } footer: {
                Text("Журнал измеряет задержки, очередь и категории сбоев. Он не оценивает смысл ответа и не заменяет системный crash report.")
            }

            Section {
                if let profile = settings.diagnosticsPairingProfile {
                    LabeledContent("Состояние", value: delivery.state.title)
                    LabeledContent("Получатель", value: "\(profile.host):\(profile.port)")
                    LabeledContent("Отпечаток", value: profile.fingerprint)
                        .font(.caption.monospaced())
                    LabeledContent("В очереди", value: "\(delivery.pendingCount)")

                    Toggle("Автоматически отправлять на мой ПК", isOn: Binding(
                        get: { settings.automaticDiagnosticsDeliveryEnabled },
                        set: delivery.setAutomaticDelivery
                    ))
                    Button("Отправить очередь сейчас") { delivery.flushQueuedWhenActive() }
                        .disabled(!settings.automaticDiagnosticsDeliveryEnabled || delivery.pendingCount == 0)
                    Button("Удалить очередь на iPhone", role: .destructive) {
                        Task { await delivery.deleteQueuedReports() }
                    }
                    .disabled(delivery.pendingCount == 0)
                    Button("Отозвать привязку", role: .destructive) { confirmsRevoke = true }
                } else {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Сканировать QR с моего ПК", systemImage: "qrcode.viewfinder")
                    }
                    TextField("Или вставьте одноразовый код", text: $pairingCode, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...5)
                    Button {
                        pair()
                    } label: {
                        if isPairing { HStack { ProgressView(); Text("Привязываю…") } }
                        else { Text("Проверить и привязать") }
                    }
                    .disabled(isPairing || pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Добровольная доставка на ПК")
            } footer: {
                Text("До явной привязки и включения переключателя отчёты не отправляются. Канал однонаправленный: ПК не может менять промпты, провайдеров или выполнять команды на iPhone. Уже доставленные копии удаляются на ПК отдельно.")
            }

            Section {
                Label("Нет текста разговоров и ответов", systemImage: "text.badge.xmark")
                Label("Нет OCR, фото и аудио", systemImage: "photo.badge.exclamationmark")
                Label("Нет ключей, URL и имён профилей", systemImage: "key.slash")
                Label("Только локальные ID, build, фазы, время и категории ошибок", systemImage: "checkmark.shield")
            } header: {
                Text("Что попадёт в экспорт")
            }

            Section("Последние события") {
                if snapshot.events.isEmpty {
                    Text("Пока событий нет")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.events.suffix(20).reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(event.kind)).font(.subheadline.weight(.semibold))
                            HStack {
                                Text(event.occurredAt, format: .dateTime.hour().minute().second())
                                if let duration = event.durationMilliseconds { Text("\(duration) мс") }
                                if let error = event.error, error != .none { Text(error.rawValue) }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    if isPreparing {
                        HStack { ProgressView(); Text("Готовлю безопасный архив…") }
                    } else {
                        Label("Подготовить экспорт", systemImage: "shippingbox")
                    }
                }
                .disabled(isPreparing)

                if let export {
                    ShareLink(item: export.fileURL) {
                        Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                    }
                    Text("\(export.eventCount) событий · ID \(export.exportID.uuidString.prefix(8))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button("Удалить локальную диагностику", role: .destructive) {
                    confirmsDelete = true
                }
            } footer: {
                Text("Файл .quickcue-diagnostics создаётся только по нажатию. Отправка через системное «Поделиться» остаётся полностью ручной.")
            }
        }
        .navigationTitle("Диагностика")
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("Удалить локальную диагностику?", isPresented: $confirmsDelete) {
            Button("Удалить", role: .destructive) {
                Task {
                    await recorder.deleteAll()
                    export = nil
                    await refresh()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("История разговоров, фото и ключи не затрагиваются.")
        }
        .confirmationDialog("Отозвать привязку к ПК?", isPresented: $confirmsRevoke) {
            Button("Отозвать", role: .destructive) { delivery.revoke() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Автоматическая отправка сразу прекратится, а секрет пары будет удалён из Keychain. Уже полученные ПК отчёты не удалятся.")
        }
        .fullScreenCover(isPresented: $showsScanner) {
            NavigationStack {
                PairingQRScanner { code in
                    pairingCode = code
                    showsScanner = false
                    pair()
                } onError: { message in
                    errorMessage = message
                    showsScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("QR привязки")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Закрыть") { showsScanner = false }
                }
            }
        }
        .alert("Диагностика", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareExport() {
        isPreparing = true
        Task {
            do { export = try await recorder.export() }
            catch {
                errorMessage = (error as? DiagnosticsArchiveError)?.localizedDescription
                    ?? "Не удалось подготовить диагностический архив. Повторите попытку."
            }
            isPreparing = false
            await refresh()
        }
    }

    private func pair() {
        let code = pairingCode
        isPairing = true
        Task {
            do {
                try await delivery.pair(using: code)
                pairingCode = ""
            } catch is CancellationError {
                // A new pairing attempt or background transition superseded this one.
            } catch {
                errorMessage = (error as? DiagnosticsPairingError)?.localizedDescription
                    ?? "Не удалось проверить защищённую привязку. Создайте новый QR на ПК."
            }
            isPairing = false
            await refresh()
        }
    }

    private func refresh() async {
        snapshot = await recorder.snapshot()
    }

    private func title(_ kind: DiagnosticEventKind) -> String {
        switch kind {
        case .schedulerCounts: "Очередь обновлена"
        case .sessionStarted: "Сессия начата"
        case .sessionEnded: "Сессия завершена"
        case .requestQueued: "Запрос поставлен в очередь"
        case .requestStarted: "Запрос начат"
        case .firstToken: "Получен первый текст"
        case .requestAttemptFinished: "Попытка завершена"
        case .requestFinished: "Ответ завершён"
        case .requestCancelled: "Запрос отменён"
        case .speechPhase: "Фаза микрофона"
        case .speechFinalized: "Фраза подтверждена"
        case .cameraCaptured: "Снимок сделан"
        case .speakerCorrected: "Роль исправлена вручную"
        case .deliveryQueued: "Отчёт ждёт отправки"
        case .deliverySucceeded: "Отчёт доставлен"
        case .deliveryFailed: "Доставка не удалась"
        case .pairingSucceeded: "ПК привязан"
        case .pairingRevoked: "Привязка отозвана"
        }
    }
}
