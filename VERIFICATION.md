# Проверка версии 0.2

## Пройдено в текущей Windows-среде

- Исходники SwiftUI, SwiftData, новая вкладка «Диалог», быстрый снимок и тесты присутствуют; пустых файлов нет.
- `project.yml` разобран независимым YAML-парсером без синтаксических ошибок.
- `Info.plist` и `QuickCue.entitlements` являются валидным XML.
- Все `Contents.json` в asset catalog являются валидным JSON.
- Все локальные Markdown-ссылки ведут на существующие файлы.
- Поиск типичных plaintext API-key шаблонов не нашёл секретов.
- Новый App Icon: 1024×1024 PNG, 24-bit RGB без alpha-канала.
- Deployment target указан как iOS 26.0, проектная версия Xcode — 26.0.

## Нельзя подтвердить на Windows

- Генерацию `QuickCue.xcodeproj` утилитой XcodeGen.
- Компиляцию SwiftUI/SwiftData против iOS 26 SDK.
- XCTest в iOS Simulator до первого запуска обновлённого GitHub Actions.
- Code signing, архив и App Store Connect validation.
- Разрешения, камера, Apple Speech и задержки на физическом iPhone 15 Pro Max.
- Реальные API-вызовы: проект намеренно не содержит ключей.

Перед TestFlight выполните macOS-команды и device smoke test из `README.md` и `docs/TESTFLIGHT.md`. Эта статическая проверка не заменяет Xcode build.

