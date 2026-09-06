# QuickCue Receiver для Windows

Локальный приёмник получает только диагностические архивы QuickCue после явной привязки. Он не принимает аудио, фото, текст разговоров, команды для iPhone или настройки AI. Публичный сервер и tunnel не требуются: указывается один IPv4-адрес ПК в домашней/рабочей локальной сети.

## Однократная установка

Откройте PowerShell в корне репозитория:

```powershell
py -m venv .receiver-venv
.\.receiver-venv\Scripts\python.exe -m pip install -r tools\quickcue_receiver\requirements.txt
.\.receiver-venv\Scripts\python.exe tools\quickcue_receiver\receiver.py init
```

Закрытый ключ и пары сохраняются в `%LOCALAPPDATA%\QuickCueReceiver\receiver-state.dpapi` в защите Windows DPAPI для текущего пользователя. Не копируйте этот файл на другой ПК и не публикуйте его.

## Привязка iPhone

1. Узнайте IPv4-адрес именно текущего LAN-интерфейса командой `ipconfig`, например `192.168.1.10`. Не используйте публичный адрес.
2. Создайте код и QR, подставив этот адрес:

```powershell
.\.receiver-venv\Scripts\python.exe tools\quickcue_receiver\receiver.py invite --host 192.168.1.10
```

3. На iPhone откройте `Настройки → Диагностика → Привязать ПК`, считайте появившийся `pairing-qr.png` и проверьте короткий fingerprint.
4. Запустите приёмник на том же адресе:

```powershell
.\.receiver-venv\Scripts\python.exe tools\quickcue_receiver\receiver.py serve --host 192.168.1.10
```

Код привязки одноразовый и действует 10 минут. Windows Firewall может отдельно запросить доступ для Python к частной сети; не разрешайте публичные сети.

## Отправка и анализ

Автодоставка остаётся выключенной после привязки. Включите её отдельным переключателем в QuickCue только если хотите отправлять отчёт после завершения сессии. Валидные файлы появятся в `%LOCALAPPDATA%\QuickCueReceiver\Inbox`.

Ручной экспорт или принятый файл анализируется полностью офлайн:

```powershell
.\.receiver-venv\Scripts\python.exe tools\analyze_quickcue_diagnostics.py "C:\path\report.quickcue-diagnostics" --output "C:\path\report.md"
```

Анализатор сначала проверяет schema, размеры, имена ZIP-файлов и checksums. Содержимое отчёта считается данными и ничего не запускает.

## Отключение

В QuickCue нажмите `Отозвать привязку`, чтобы немедленно удалить секрет iPhone и прекратить новые отправки. Затем удалите пару и на ПК, используя ID из экрана QuickCue:

```powershell
.\.receiver-venv\Scripts\python.exe tools\quickcue_receiver\receiver.py revoke 00000000-0000-0000-0000-000000000000
```

Выключение или отзыв не удаляют ранее полученные архивы. Их нужно удалить из `Inbox` отдельно.
