# Xcode и TestFlight

## Локальный запуск на iPhone 15 Pro Max

1. На macOS установите Xcode 26 или новее с iOS 26 SDK и XcodeGen.
2. В корне проекта выполните `xcodegen generate`.
3. Откройте `QuickCue.xcodeproj`.
4. В target `QuickCue` → Signing & Capabilities выберите личную Apple Developer Team и при необходимости замените Bundle Identifier.
5. Подключите iPhone 15 Pro Max, подтвердите Developer Mode и выберите устройство как run destination.
6. Первый запуск оставьте в Mock. Разрешите микрофон, Speech Recognition, камеру и Bluetooth только при запросе соответствующей функции.
7. Проверьте ручной вопрос, потоковую карточку, историю и фотографию до включения реального провайдера.

## Архив и TestFlight

1. Установите уникальные `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `project.yml`, снова выполните `xcodegen generate`.
2. В Xcode выберите `Any iOS Device (arm64)` и `Product → Archive`.
3. В Organizer выполните `Distribute App → App Store Connect → Upload`.
4. В App Store Connect заполните privacy answers: микрофон, речь, фото и отправка пользовательского содержимого выбранному AI-провайдеру.
5. Для внешних тестировщиков не раздавайте сборку с личными provider keys. Сначала поставьте серверный прокси, rate limiting и пользовательскую авторизацию.
6. Добавьте сборку во внутреннюю группу TestFlight, затем отдельно отправляйте на Beta App Review при внешнем тестировании.

Перед загрузкой обязательно выполнить тесты на macOS и реальный smoke test на iPhone. Windows-проверка не заменяет компиляцию Xcode, code signing и проверку разрешений на устройстве.
