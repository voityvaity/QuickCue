# Проверка версии 0.2

## Пройдено

- GitHub Actions `Build QuickCue iOS #8` успешно завершился для commit `ad4cdde`: XcodeGen создал проект, приложение собралось для iOS Simulator, все unit-тесты прошли, затем собрался вариант для физического iPhone.
- Создан артефакт `QuickCue-unsigned-ipa` размером около 2,9 МБ для последующей подписи через Sideloadly.
- Проверенная сборка: <https://github.com/voityvaity/QuickCue/actions/runs/33496467970>.

## Дополнительно проверено в Windows

- Исходники SwiftUI, SwiftData, новая вкладка «Диалог», быстрый снимок и тесты присутствуют; пустых файлов нет.
- `project.yml` разобран независимым YAML-парсером без синтаксических ошибок.
- `Info.plist` и `QuickCue.entitlements` являются валидным XML.
- Все `Contents.json` в asset catalog являются валидным JSON.
- Все локальные Markdown-ссылки ведут на существующие файлы.
- Поиск типичных plaintext API-key шаблонов не нашёл секретов.
- Новый App Icon: 1024×1024 PNG, 24-bit RGB без alpha-канала.
- Deployment target указан как iOS 26.0, проектная версия Xcode — 26.0.

## Остаётся проверить на физическом iPhone

- Code signing, архив и App Store Connect validation.
- Разрешения, камера, Apple Speech и задержки на физическом iPhone 15 Pro Max.
- Реальные API-вызовы: проект намеренно не содержит ключей.

Перед TestFlight выполните device smoke test из `README.md` и `docs/TESTFLIGHT.md`. Успешная CI-сборка не заменяет проверку камеры, микрофона и реального API непосредственно на iPhone.

