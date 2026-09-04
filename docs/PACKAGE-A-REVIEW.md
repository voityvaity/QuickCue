# QuickCue A0–A3 — локальный результат и передача на проверку

Дата: 4 сентября 2026. **A-close выполнен локально: два P2 независимого ревью исправлены и покрыты регрессиями, но исправление пользовательского сбоя на iPhone ещё не доказано. Не готовый релиз.** Пакеты B–I не начинались.

## 1. Исходная точка

- Ветка `codex/quickcue-v0.3.1`, локальный HEAD после безопасного fast-forward: `c55294f4d4c88ff1ef02cb89d3e07b8da01f8e99`.
- Включены удалённые изменения 590e85c/c55294f: полезный детерминированный transport seam сохранён.
- Текущий пакет — незакоммиченные локальные изменения поверх этого SHA. Push и новый GitHub Actions не выполнялись. Старый зелёный CI не подтверждает этот diff.
- Версия намеренно остаётся **0.3.1 (4)**. Новую сборку отличает revision из Info.plist; CI передаёт checkout SHA и проверяет его в собранном .app. При локальной сборке без metadata — `unknown`, не выдуманный SHA.
- Исследовательские файлы `analysis/2026-09-04/` существовали до реализации. Их наличие не означает разрешения публиковать видео/скриншоты конкурентов.
- Ключи не искались, не создавались, не использовались в этом пакете. Новых платных запросов нет.

## 2. Что доказано, а что нет

Чтением исходной ревизии подтверждены отдельные дефекты:

1. Невалидный JSON data-event превращался в пустой массив событий, скрывая повреждение потока.
2. Chat Completions не учитывал `finish_reason`: например, `length` нельзя отличить от нормального окончания.
3. Проверочный запрос с лимитом 32 наследовал общий системный промпт с несколькими тезисами, хотя просил одно слово.
4. Тестовый parser отличался от production-пути; HTTP-фикстуры не проверяли настоящий URLSession.
5. Transport делал общий trim полезной нагрузки и отправлял незавершённый event при EOF.

**Не доказано:** что именно `.lines` теряет пустые строки в целевой версии Foundation и является причиной сбоя на телефоне. Новый byte decoder — самостоятельное усиление надёжности и кандидат на устранение framing-проблемы. Нельзя объявлять гипотезу подтверждённой по наличию нового кода.

Предыдущий отдельно разрешённый прямой тест DeepSeek с ПК подтвердил полный stream, но не установленный IPA. Этот тест здесь не повторялся. На телефоне ещё требуется сопоставить встроенный/custom профиль, model ID и revision без раскрытия ключа.

## 3. Изменённые файлы и назначение

Пути ниже относительно корня репозитория. Новые файлы обозначены «новый».

| Файл | Изменение |
|---|---|
| `QuickCue/Core/AI/SSEDecoder.swift` — новый | Общий incremental byte decoder; LF/CRLF/CR, BOM, comments, multiline, один optional space; лимит event 1 MiB; неполный EOF не dispatch-ится |
| `QuickCue/Core/AI/SSETransport.swift` | Настоящие AsyncBytes → общий decoder; MIME/HTTP checks; 8 MiB stream cap; wall deadline 60 с; bounded queue 256 событий с явной ошибкой переполнения; отмена underlying task; same-origin redirect policy |
| `QuickCue/Core/AI/ChatCompletionStreamDecoder.swift` — новый | Stateful `[DONE]`, text presence, finish categories, reasoning-only; неизвестное именованное расширение не может завершить ответ |
| `QuickCue/Core/AI/StreamFailure.swift` — новый | Закрытый набор безопасных ошибок без server body/произвольной причины |
| `QuickCue/Core/AI/RemoteProviderSupport.swift` | Malformed JSON не пропускается молча; terminal semantics Responses/Anthropic; usage остаётся неизвестным, если невалиден; validator считает события |
| `QuickCue/Core/AI/DeepSeekProvider.swift` | Shared compatible stream с stateful decoder, request ID и безопасными счётчиками; существующий `thinking.disabled` сохранён; модель не менялась |
| `QuickCue/Core/AI/YandexGPTProvider.swift` | Тот же Chat Completions decoder и terminal lifecycle; URI/auth не менялись |
| `QuickCue/Core/AI/CustomOpenAIProvider.swift` | Тот же decoder; пользовательские адреса/модель/auth сохраняются |
| `QuickCue/Core/AI/OpenAIProvider.swift` | Передача request ID, счётчики, выход на protocol terminal |
| `QuickCue/Core/AI/AnthropicProvider.swift` | Передача request ID, счётчики, учёт stop reason через decoder |
| `QuickCue/Core/AI/ProviderDiagnostics.swift` | Нейтральный собственный prompt проверки, прежние 32 токена/15 с, отдельные категории HTTP/stream, request ID/build в отчёте |
| `QuickCue/Core/Models/AIModels.swift` | Optional metadata в Codable connection report; SwiftData schema не менялась |
| `QuickCue/Support/LatencyLogger.swift` | Только allow-listed errors, request ID/provider kind и text/usage/terminal counters |
| `QuickCue/Support/BuildIdentity.swift` — новый | Version/build/revision из bundle; неизвестная или невалидная ревизия не подменяется |
| `QuickCue/Support/ConnectionDiagnosticSummary.swift` — новый | Краткий ручной экспорт статуса без произвольных model/name/URL/error strings |
| `QuickCue/Features/Settings/SettingsView.swift` | Небольшой раздел «О приложении» и ручной share номера сборки |
| `QuickCue/Features/Settings/ProviderConnectionStatus.swift` | Ручной share результата проверки; никакой автоматической передачи на ПК |
| `QuickCueTests/ProviderHTTPTests.swift` | Убран второй fixture parser; используется production SSEDecoder; явные blank-line delimiters; DeepSeek payload/probe regression |
| `QuickCueTests/ProviderReliabilityTests.swift` | Адаптация к throwing JSON parser; прежние проверки сохранены |
| `QuickCueTests/SSEParserTests.swift` | Адаптация к throwing parser; прежние delta/usage/DONE проверки сохранены |
| `QuickCueTests/StreamTerminalTests.swift` — новый | Length/policy/resource/tool/reasoning/empty/EOF/malformed/unknown-extension и safe error regressions |
| `QuickCueTests/BuildIdentityTests.swift` — новый | Metadata, legacy Codable report, исключение произвольных полей из экспорта |
| `TransportTests/SSEDecoderTests.swift` — новый | Фрагментация на каждом байте кириллицы/emoji, BOM/line endings, EOF, UTF-8, лимиты, synthetic DeepSeek wire |
| `TransportTests/FoundationLinesProbeTests.swift` — новый | Фиксирует результат `.lines` без заранее заданного вывода гипотезы |
| `TransportTests/URLSessionLoopbackTests.swift` — новый | Настоящий TCP/URLSession: первый event до EOF, baseline `.lines`, fragmentation, cancel/socket closure, HTTP/MIME/EOF, redirect, deadline/byte cap |
| `Package.swift` — новый | macOS test harness компилирует те же production SSEDecoder/SSETransport; XcodeGen остаётся сборкой приложения |
| `project.yml` | Safe default source revision и Info.plist substitution, без изменения version/build/ATS |
| `.github/workflows/ios-build.yml` | Подготовлен macOS `swift test`, артефакт transport log, revision на трёх Xcode build/test вызовах, проверка metadata в собранном .app |
| `.gitignore` | Игнорирование локальных SwiftPM build/cache |
| `VERIFICATION.md` | Актуальная матрица вместо устаревшего утверждения о URLProtocol |
| `docs/RELEASE-0.3.1.md` | Уточнён механизм HTTP fixtures и граница текущей проверки |
| `docs/PACKAGE-A-REVIEW.md` — новый | Этот handoff, критерии и риски |
| `README.md` | Ссылка на статус локального пакета A |
Локальные планирующие материалы `analysis/2026-09-04/` обновляются отдельно как рабочий handoff и **не входят в публикуемый технический commit**: там находятся исследовательские тексты и ссылки на личные материалы. Их не следует добавлять через `git add .`.

Дополнение A-close после независимого review:

- Cancellation разделён на два детерминированных теста. Случай after-first-event ждёт событие, которое уже выдал production `AsyncSequence`, и лишь затем отменяет consumer; server-side `received` больше не выдаётся за доставку клиенту.
- `response.completed` требует объект `response` со статусом `completed`; malformed status/usage/token counts дают закрытую ошибку `malformed_event`.
- Anthropic `message_delta` требует объект `delta` и строковый `stop_reason`; неверные/missing/null terminal fields и malformed usage больше не могут перейти к успешному `message_stop`.
- Валидный `stop_sequence: null` и необязательный `usage: null` сохранены. HTTP/reliability fixtures приведены к контрактному terminal payload.

## 4. Матрица проверок

| Проверка | Выполнено | Результат / ограничение |
|---|---|---|
| Сверка и fast-forward ветки | Да | Основа c55294f, без reset и потери `analysis/` |
| `.github/scripts/validate_repository.py` | Да | PASS: privacy, release version, поиск вероятных ключей, включая untracked text candidates; не полная security certification |
| Tree-sitter всех Swift исходников | Да | PASS: 78 файлов с legacy fixture/Package.swift; ноль syntax-error roots; повторный A-close срез 76 app/iOS/transport файлов тоже PASS. **Не typecheck, не Xcode build** |
| project/workflow YAML | Да | PASS |
| Info/entitlements/privacy plist и asset JSON | Да | PASS |
| Syntax встроенного Python CI metadata checker | Да | PASS; against an actual .app не выполнялся |
| `git diff --check` | Да | PASS |
| 114 iOS XCTest-методов в исходниках | Нет | На Windows нет Swift/Xcode; добавлены 2 malformed-terminal regressions; число методов — не число прошедших тестов |
| 20 macOS transport XCTest-методов | Нет | Before-headers и after-first-event cancellation разделены; нет Darwin/Foundation runtime, поэтому фрейминг и закрытие сокетов пока не подтверждены |
| Darwin `.lines` baseline | Нет | Гипотеза не подтверждена и не опровергнута |
| Новая Simulator/iphoneos сборка, metadata в IPA | Нет | Новый CI не запущен, отправка изменений не разрешалась |
| 5/5 DeepSeek inside QuickCue | Нет | Нужна сборка и iPhone; платный тест запускает пользователь |
| Cancel/offline/invalid-key, новая сессия | Нет | Автоматические regressions подготовлены/сохранены; нужна device-проверка |
| Обновление поверх старой установки, история/Keychain | Нет | Устройство недоступно; данные/схема/ключи не сбрасывались |

## 5. Как продолжить проверку

### На macOS / разрешённом CI

1. Просмотреть diff перед публикацией. **Не делать `git add .`**, чтобы случайно не включить локальные research media. Коммит/публикация — только по разрешению пользователя.
2. Выполнить `swift test` из корня. Сохранить stdout целиком, включая `Darwin Foundation .lines` и `FOUNDATION_NETWORK_LINES`.
3. Если baseline сохраняет blank lines, зафиксировать «гипотеза `.lines` не подтверждена» и продолжить диагностику installed build / семантического слоя. Не ослаблять тест ради красивого результата.
4. Сопоставить baseline с c55294f: probe воспроизводит Foundation path, но сам по себе не является запуском старого IPA. При необходимости отдельно собрать/прогнать прежний transport в изолированной worktree, не откатывая эту рабочую копию.
5. Пройти Xcode Simulator build, все XCTest, iphoneos build. Проверить `QuickCue-build-identity`: версия 0.3.1, build 4, **точный SHA данного checkout**.
6. Transport tests используют настоящий TCP на `127.0.0.1`. HTTP разрешается только явным test-конструктором и только loopback. У приложения нет ATS exceptions; реальные provider URLs должны быть HTTPS.
7. Если XCTest не собирается или loopback падает — исправить тест/production по конкретному результату, сохранив разделение framing/terminal/cancellation. Здесь Swift typecheck не выполнен.

Ни provider key, ни GitHub secret для этих тестов не нужны. CI не должен автоматически запускать платную генерацию.

### На iPhone 15 Pro Max

1. После успешного CI установить IPA поверх старого приложения с тем же bundle ID/подписью. **Не удалять старую установку.** Проверить историю, фото и сохранённый ключ.
2. Открыть Настройки → О приложении; сверить `0.3.1 (4)` и ревизию с артефактом CI. Поделиться номером сборки, если есть ошибка.
3. Выбрать **встроенный DeepSeek**, убедиться в ожидаемом model ID. Не менять одновременно модель/ключ/тарифы. Для изоляции теста обычных ответов поставить primary=fallback=DeepSeek, чтобы не запускать второй платный сервис.
4. Выполнить один тест подключения. Он должен дождаться непустого текста и терминатора, а не только принятия ключа. Если не прошёл — поделиться безопасным результатом проверки, не секретом.
5. После успеха задать вручную 5 коротких разных вопросов; записать 5/5 или точное число успехов, TTFT и код сбоя. Это платные запросы, их запускает пользователь.
6. Начать ответ → отменить. Не должно быть дописывания после отмены. Повторить: завершить сессию → начать новую; старый ответ не должен попасть в новую.
7. Включить авиарежим → пробный вопрос/проверка: понятная сетевая ошибка, не «ключ неверный». Восстановить сеть, новый запрос проходит.
8. В тестовом профиле временно указать заведомо неверный ключ (сохранить действующий вне чата), проверить отдельную ошибку авторизации; восстановить правильный ключ вручную. Не провоцировать реальные 429 или billing оплатами — эти категории покрываются fixtures.
9. Открыть другой экран/фон во время запроса: foreground-only остановка остаётся прежней. Настройка поведения при смене вкладок относится к B и здесь не реализуется.

## 6. Незакрытые риски и границы

- A0: локальная подготовка завершена; фактическое соответствие IPA/SHA ожидает CI.
- A1: тесты написаны, доказательная проверка Darwin **не выполнена**.
- A2: hardening реализован; P2-пробел теста cancellation закрыт в исходниках, но runtime semantics cancellation/redirect/first-event **не подтверждены** до CI.
- A3: раздельные ошибки и regressions реализованы; P2 malformed terminal закрыт в исходниках, но iOS XCTest и 5/5 real requests **не подтверждены**.
- Порог 1 MiB/event, 8 MiB/stream, 60 с total и 256 queued events — защитные пределы для коротких ответов. Они не являются лимитами тарифа и требуют совместимости с реальными шлюзами.
- Strict MIME/UTF-8/JSON может выявить ранее маскируемую несовместимость шлюза. Не отключать проверки автоматически. Уточнить конкретный официальный формат перед добавлением исключения.
- Для совместимых Chat APIs без `finish_reason` принимается `[DONE]` плюс текст. Известная ненормальная причина не маскируется этим терминатором. `reasoning_content` никогда не становится пользовательским ответом.
- SDK/Swift concurrency и lifecycle сети нельзя подтвердить parser-проверкой. Главный следующий барьер — macOS CI, затем физический iPhone, не новый UI.
- Полный accounting connection probe и расширенные protocols/models остаются в B; текущий тест может стоить денег и не добавлен в session usage ledger этим пакетом.
- Bytes/event/text/usage/terminal counters пишутся в локальный OSLog (`ru.quickcue.app`). Короткий ShareLink содержит build/request ID, категорию и время, но не весь OSLog; полноценный diagnostic bundle остаётся следующим этапом.
- Автотелеметрия, видеоанализ, новые модели/цены, onboarding, поведение микрофона, камера, диаризация не менялись. Ручной share короткого результата — не реализация F/v0.7.

## Источники контрактов

- [WHATWG SSE parsing](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream): framing/EOF/space/BOM.
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/): finish reasons и streaming.
- [OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions): content/usage/terminal semantics.
- [Apple URLSession AsyncBytes.task](https://developer.apple.com/documentation/foundation/urlsession/asyncbytes/task): явная отмена сетевой задачи. Runtime evidence всё равно должен дать тест.
