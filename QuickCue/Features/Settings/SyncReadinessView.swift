import SwiftUI

struct SyncReadinessView: View {
    private let report = SyncReadinessEvaluator.current()

    var body: some View {
        List {
            Section {
                Label("Перенесено — не включено в этой сборке", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text("Компиляция сама по себе не доказывает CloudKit. Текущая персональная установка не имеет подтверждённого iCloud entitlement и проверки на двух устройствах.")
                    .font(.footnote)
            } header: { Text("Честный статус") }

            Section("Что нужно до реализации") {
                ForEach(report.missingRequirements, id: \.self) { requirement in
                    Label(requirement, systemImage: "circle")
                }
            }

            Section {
                ForEach(SyncReadinessEvaluator.futureDataDisclosure, id: \.self) {
                    Label($0, systemImage: "icloud.and.arrow.up")
                }
            } header: { Text("Только после отдельного согласия сможет передаваться") }

            Section {
                ForEach(SyncReadinessEvaluator.alwaysExcluded, id: \.self) {
                    Label($0, systemImage: "hand.raised.fill")
                }
            } header: { Text("Не попадёт в синхронизацию") }

            Section {
                Label("Локальная работа доступна без iCloud", systemImage: "iphone")
                Label("Резервная копия работает отдельно", systemImage: "externaldrive")
            } footer: {
                Text("Будущая проверка должна покрыть offline→online, одновременное редактирование, удаление/tombstone, повтор доставки, выход из аккаунта, квоты и большие фото. До этого статус не станет «готово».")
            }
        }
        .navigationTitle("Синхронизация")
    }
}
