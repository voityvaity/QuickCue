# Проверка QuickCue — локальный пакет A0–A3

## Статус на 4 сентября 2026

**Код подготовлен, новый релиз и устранение сбоя на iPhone не подтверждены.** Основа — `c55294f4d4c88ff1ef02cb89d3e07b8da01f8e99`; текущие изменения ещё не закоммичены и не отправлены. Новый GitHub Actions не запускался. Версия остаётся 0.3.1 (build 4); будущий CI запишет точный source revision.

Полный перечень изменённых файлов, статусы A0/A1/A2/A3, риски и device checklist: [PACKAGE-A-REVIEW.md](docs/PACKAGE-A-REVIEW.md).

Подтверждено локально на Windows:

- Поиск вероятных секретов, privacy manifest и номера версии: PASS (`.github/scripts/validate_repository.py`, включая untracked text candidates).
- Tree-sitter всех 78 Swift-файлов приложения, тестов, legacy fixture и Package.swift: PASS. Это **не typecheck, не XCTest и не проверка Apple API**.
- XML/plist, asset JSON и два YAML-файла проекта/CI: PASS.
- Синтаксис встроенного CI Python-checker для build identity: PASS. С реальным .app не запускался.
- `git diff --check`: PASS.

Подготовлены, но **не выполнены**:

- 114 iOS XCTest-методов: существующие 99 сохранены, добавлены 15, включая два malformed-terminal regressions A-close.
- 20 macOS transport XCTest-методов: общий byte decoder, Foundation .lines probes, настоящий URLSession/TCP loopback, раздельная отмена до headers и после первого полученного event, redirect, MIME/HTTP/EOF/deadline/лимиты.
- Simulator/iphoneos build, проверка SHA в .app/IPA, 5/5 DeepSeek в QuickCue на телефоне, update поверх установленной версии и сохранность истории/Keychain.

HTTP adapter tests после c55294f используют детерминированный `streamFactory`, **не URLProtocol**. В текущем пакете fixtures проходят через тот же SSEDecoder, что production. Отдельный macOS harness не использует ни URLProtocol, ни streamFactory. Полезная заглушка не выдаётся за доказательство работоспособности URLSession.

Гипотеза о потере blank lines в Foundation `.lines` пока не доказана. Неправильный trim, EOF-dispatch, молчаливое отбрасывание невалидного JSON и игнорирование finish reasons подтверждены чтением прежних исходников; причинность именно пользовательского сбоя требует runtime evidence.

Обновление устанавливать поверх прежнего с тем же bundle ID и совместимой подписью. Старую установку не удалять. Пакеты B–I не начинались; автоматической телеметрии/новых ключей/платных проверок в этом проходе нет.

## Исторический результат версии 0.3

Ниже сохранён отчёт прошлого релиза; повторно его CI в этом этапе не запускали.

### Пройдено в v0.3

- GitHub Actions `Build QuickCue iOS` успешно завершился для commit `85fc3c5`: XcodeGen создал проект, приложение собралось для iOS Simulator, все unit-тесты прошли, затем собрался вариант для физического iPhone.
- Создан артефакт `QuickCue-unsigned-ipa` размером около 3,2 МБ для последующей подписи через Sideloadly.
- Проверенная сборка ветки: <https://github.com/voityvaity/QuickCue/actions/runs/33529861906>.
- Новые тесты проверяют несколько независимых пользовательских провайдеров, выбор основного/резервного, нормализацию HTTPS endpoint и извлечение вероятного API-ключа из локального OCR.

### Дополнительно проверено в Windows для v0.3

- Исходники SwiftUI, SwiftData, список пользовательских провайдеров, редактор промпта и импорт ключа по фото присутствуют; пустых файлов нет.
- `Info.plist` и `QuickCue.entitlements` являются валидным XML.
- Все `Contents.json` в asset catalog являются валидным JSON.
- Поиск типичных plaintext API-key шаблонов в production-файлах не нашёл секретов.
- Новый App Icon: 1024×1024 PNG, 24-bit RGB без alpha-канала.
- Deployment target указан как iOS 26.0, версия приложения — 0.3.0 (build 3).

### Исторический список проверки на физическом iPhone

- Подпись новой IPA через Sideloadly и обновление установленной версии.
- Камеру API-ключа: качество OCR и ручную проверку похожих символов.
- Добавление двух пользовательских провайдеров, их выбор как основного/резервного и реальные streaming-ответы.
- Реальный YandexGPT после привязки billing account и выпуска нового ключа.
- Задержки и качество Apple Speech на iPhone 15 Pro Max.

Проект намеренно не содержит реальных API-ключей. Успешная CI-сборка не заменяет проверку камеры, микрофона и внешних API непосредственно на iPhone.

