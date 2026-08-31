# QuickCue — быстрый AI-помощник для iPhone

SwiftUI MVP для **iPhone 15 Pro Max** с минимальной версией **iOS 26.0**. Приложение работает только пока открыто: потоково распознаёт русскую речь, локально замечает вопросы, показывает короткий ответ тезисами, фотографирует программные задачи и хранит историю на устройстве.

Проект стартует в **Mock-режиме** и не требует реальных API-ключей. Подключаемые клиенты для OpenAI, DeepSeek, Anthropic Claude, xAI Grok и YandexGPT подготовлены, но сеть включается только после явного отключения Mock и сохранения ключа в Keychain.

## Что уже работает в MVP

- SwiftUI-интерфейс из четырёх вкладок: эфир, камера, история, настройки.
- Явный запуск/остановка микрофона, `ru_RU`, partial speech results.
- Финализация фразы после паузы 650 мс и локальный `QuestionDetector`.
- Ручной ввод вопроса для быстрой проверки без речи.
- Потоковая карточка ответа и измерение time-to-first-token/полного времени.
- Защита от одинакового вопроса в течение 8 секунд и не более двух AI-запросов одновременно.
- SwiftData для сессий, расшифровок, ответов, фото и usage.
- Камера, Vision OCR для русского/английского текста, локальное сохранение JPEG.
- Keychain для секретов; ключи не лежат в исходниках, plist или xcconfig.
- Latency fallback: резервный запрос стартует после настраиваемой задержки, выигрывает первый текстовый поток.
- Мягкие лимиты: 150 вопросов и 30 фотографий за сессию, контекст 5 минут, месячный бюджет 2 000 ₽.
- Учёт input/output tokens и оценка стоимости по актуальным тарифам, которые владелец вводит для каждого провайдера.
- Ручная экранная кнопка камеры и слой `CaptureTriggering` для кастомной BLE-кнопки.
- Unit tests для детектора, mock stream, SSE parser и стоимости.
- Готовый 1024×1024 App Icon без текста для архива/TestFlight.

## Что намеренно не заявлено как готовое

- Проект создан на Windows, где нет Xcode/iOS SDK. Структура и исходники проверяются статически, но финальную компиляцию, подпись, permissions и TestFlight нужно подтвердить на macOS.
- Обычный Bluetooth selfie remote обычно эмулирует volume key. Надёжного публичного API для превращения такого нажатия в команду приложения нет. В MVP нет MPVolumeView/KVO-хаков; поддерживается честная BLE-точка расширения с известными service/characteristic UUID.
- Модели и тарифы быстро меняются. ID моделей редактируются на устройстве, денежные тарифы по умолчанию равны нулю и должны быть сверены перед live-тестом.
- Apple Speech может обращаться к сети. Приложение не хранит аудио, но не обещает полностью offline speech recognition.
- Прямые ключи в Keychain подходят только для личной сборки. Перед распространением другим пользователям клиенты следует направить на собственный backend, где лежат provider keys, rate limits и billing rules.
- Для YandexGPT фото проходит через локальный OCR. Прямой vision-запрос в текущем адаптере не включён.

## Быстрый запуск на macOS

Требуются Xcode 26 или новее с iOS 26 SDK, macOS, Apple Developer account и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd /path/to/QuickCue-iOS
xcodegen generate
open QuickCue.xcodeproj
```

В Xcode:

1. Выберите target `QuickCue` → Signing & Capabilities → свою Team.
2. Если Bundle ID занят, измените `PRODUCT_BUNDLE_IDENTIFIER` в `Config/Shared.xcconfig`.
3. Выберите iPhone 15 Pro Max с iOS 26 как устройство запуска.
4. Запустите приложение. Mock включён автоматически.
5. Разрешите микрофон/Speech для вкладки «Эфир» и камеру для вкладки «Камера».
6. Нажмите «Начать слушать» или введите вопрос вручную. Ответ должен прийти частями примерно за 0,2–0,5 с в Mock.

`QuickCue.xcodeproj` намеренно игнорируется: источник истины — `project.yml`, чтобы настройки проекта были обозримы и воспроизводимы.

## Подключение реального провайдера

1. В «Настройки → Провайдеры» откройте нужного провайдера.
2. Проверьте актуальный ID модели и при необходимости измените его.
3. Введите текущую цену в рублях за 1 млн input/output tokens, если нужна денежная оценка.
4. Откройте Keychain-настройку и сохраните личный ключ. Поле никогда не показывает сохранённое значение обратно.
5. Для YandexGPT дополнительно заполните Yandex Cloud Folder ID.
6. Выберите основной и резервный провайдеры, затем выключите Mock.

Заданные по умолчанию model IDs — лишь стартовые конфигурации на дату подготовки проекта. Перед live-запросом проверьте доступность в своём аккаунте:

- OpenAI: `gpt-5.4-mini`, Responses API.
- DeepSeek: `deepseek-v4-flash`, Chat Completions, thinking disabled ради скорости.
- Claude: `claude-sonnet-5`, Messages API, adaptive thinking disabled в fast path.
- xAI: `grok-4.6`, Chat Completions.
- YandexGPT: `gpt://<folder-id>/yandexgpt/latest` — UI-название YandexGPT 5.1 Pro нужно сопоставить с доступным URI в конкретном Yandex Cloud каталоге.

Ни один ключ не включён. Фраза «подключаемые клиенты» означает, что транспорт, payload и SSE parsing реализованы, но валидность каждого аккаунта/model ID всё равно проверяется интеграционным smoke test на устройстве.

## Приоритет скорости

Цели из ТЗ:

| Этап | Цель |
|---|---:|
| Пауза/конец фразы | 300–650 мс |
| Локальное определение вопроса | до 50 мс |
| Первый фрагмент AI | желательно 1–1,5 с, допустимо до 2,5 с |
| Короткий полный ответ | желательно 3–4 с |

Время измеряется монотонными часами и пишется в `AnswerRecord` плюс unified logging category `latency`. Резервный запрос по умолчанию стартует через 1,7 с. Ответ ограничен 220 output tokens и системной инструкцией на 3–5 тезисов. DeepSeek и Claude thinking выключены в fast path.

Цели не являются гарантией: сеть, очередь провайдера, модель, prompt cache и размер изображения влияют на задержку. Автовыбор по p50/p95 оставлен следующим этапом после 50–100 реальных примеров.

## Лимиты и расходы

Искусственного жёсткого paywall нет. MVP использует три слоя:

1. Защита от ошибок: дедупликация 8 секунд, максимум 2 параллельных запроса, 30-секундный HTTP timeout.
2. Мягкие сессионные предупреждения: 150 вопросов, 30 фото; работа после предупреждения продолжается.
3. Бюджет: 2 000 ₽/месяц, предупреждения на 70%, 90% и 100%.

Каждый поток сохраняет токены, вид запроса и провайдера. Стоимость вычисляется как `inputTokens / 1M × inputRate + outputTokens / 1M × outputRate`. Из-за курсов валют, разных cache rates, image pricing и меняющихся тарифов значения вводятся вручную и считаются **оценкой**, а не банковской сверкой.

## Структура

```text
QuickCue-iOS/
├── project.yml                 воспроизводимый Xcode project
├── Config/                     Debug/Release без секретов
├── QuickCue/
│   ├── App/                    entry point и TabView
│   ├── Core/
│   │   ├── AI/                 protocol, 5 клиентов, Mock, SSE, fallback
│   │   ├── Budget/             usage и стоимость
│   │   ├── Camera/             AVFoundation preview/capture и Vision OCR
│   │   ├── Models/             SwiftData и DTO
│   │   ├── Remote/             screen/BLE trigger abstraction
│   │   ├── Session/            SessionStore и текущий контекст
│   │   ├── Settings/           UserDefaults-настройки
│   │   ├── Speech/             Apple Speech и QuestionDetector
│   │   └── Storage/            Keychain и защищённые JPEG
│   ├── Features/               Live, Camera, History, Settings
│   ├── Resources/              plist и entitlements
│   └── Support/                latency logger
├── QuickCueTests/              unit tests
└── docs/                       архитектура, privacy, TestFlight
```

Подробности: [ARCHITECTURE.md](docs/ARCHITECTURE.md), [PRIVACY.md](docs/PRIVACY.md), [TESTFLIGHT.md](docs/TESTFLIGHT.md), [VERIFICATION.md](VERIFICATION.md).

## Проверки на macOS

```bash
xcodegen generate
xcodebuild \
  -project QuickCue.xcodeproj \
  -scheme QuickCue \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max' \
  test
```

Если в установленном iOS 26 SDK нет симулятора с точным именем `iPhone 15 Pro Max`, выберите доступный iPhone simulator в Xcode и замените destination. Камеру и качество Speech обязательно проверять на физическом устройстве.

## TestFlight

Кратко: Team/Bundle ID → реальный device smoke test → `Product → Archive` → Organizer → App Store Connect → внутренняя группа TestFlight. Полный чек-лист находится в [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

## Официальные API-ориентиры

- [OpenAI Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Anthropic streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
- [xAI streaming](https://docs.x.ai/developers/model-capabilities/text/streaming)
- [Yandex AI Studio models and streaming](https://yandex.cloud/en/docs/foundation-models/concepts/yandexart/)
- [Apple Speech framework](https://developer.apple.com/documentation/speech)
- [Apple SwiftData](https://developer.apple.com/documentation/swiftdata)
- [Apple TestFlight overview](https://developer.apple.com/testflight/)

## Следующий безопасный этап

1. Скомпилировать и прогнать unit tests в актуальном Xcode.
2. На физическом iPhone измерить Speech pause → TTFT на 20 mock-вопросах.
3. Подключать по одному провайдеру и делать 5 текстовых + 2 фото smoke tests.
4. Зафиксировать реальные model IDs, p50/p95, ошибки и тарифы.
5. До внешнего TestFlight вынести ключи на backend и добавить отмену проигравшего fallback-запроса.
