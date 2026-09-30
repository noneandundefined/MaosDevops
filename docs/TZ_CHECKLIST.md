# Проверка по ТЗ

Дата проверки: 2026-10-01.

Обозначения: **готово** — есть рабочая реализация в текущем проекте;
**частично** — основа работает, но не все подпункты ТЗ реализованы;
**план** — пока только модель/заготовка либо реализации нет.

| Раздел | Статус | Что есть / чего не хватает |
|---|---|---|
| macOS 10.15, Intel, AppKit | **готово** | Deployment target 10.15 в проекте и Info.plist; `ARCHS=x86_64`; AppKit без SwiftUI/Electron. CI проверяет архитектуру и `minos` готового Mach-O. |
| Servers | **готово** | CRUD, группы, избранное, password/key auth, Test Connection. |
| Keychain / SQLite | **готово** | Секреты хранятся в Keychain; SQLite содержит только `secret_id`. Askpass получает секрет только в памяти короткоживущего SSH-процесса и не пишет его во временный файл. |
| SSH | **готово** | Системный OpenSSH, ControlMaster/ControlPath, переиспользование соединений, лимит параллельных команд, timeout, асинхронный UI. |
| Terminal | **частично** | Несколько вкладок, постоянный интерактивный shell/channel, reconnect, history-модель, нативные copy/paste, ограниченный буфер. Нет полноценной эмуляции ANSI/VT100 и точной PTY-resize интеграции. |
| Dashboard сервера | **готово** | Online/offline, hostname, OS, uptime, CPU/RAM/disk/load/network, наличие Docker/systemd. |
| Docker | **частично** | Список и Start/Stop/Restart/Logs/Live Logs/Inspect/Stats/Remove; compose ps/pull/up/down/restart/logs/build. Не выведены отдельными колонками restart count и детальная live-статистика; Docker-вкладка пока не скрывается автоматически. |
| systemd | **готово** | Список и Start/Stop/Restart/Status/Enable/Disable/Logs/Live Logs через `journalctl`. |
| Logs | **готово** | systemd/Docker/file/command, настоящий stream, pause/resume, clear, search, level filter, copy, timestamps, ограничение количества строк. |
| Monitoring | **частично** | Настраиваемый polling, сбор через один SSH round-trip, остановка на скрытом экране, сохранение и pruning истории. Переключатели 15m/1h/24h есть, но графики истории ещё не отрисовываются. |
| Problems | **частично** | Offline, disk и RAM checks. Нет анализа failed systemd/restart count Docker и быстрых кнопок непосредственно в строке проблемы. |
| Custom Actions | **готово** | Command/Poll/Stream/Check/Group, interval, working directory, environment, confirmation, display type, stop_on_error, pin в Quick Actions. Poll/Check не запускают новый цикл, пока предыдущий не завершился. |
| Quick Actions | **готово** | Пользовательские закреплённые действия, включая обязательное подтверждение опасных действий. |
| Deploy | **частично** | Последовательные шаги, статус каждого шага, confirmation, stop on error, output. Нет отдельного редактора и таблицы persisted deploy workflows; rollback делается пользовательским Action. |
| Files / SFTP | **частично** | Навигация, upload/download через SFTP поверх общего SSH master, rename/delete/mkdir, редактор разрешённых текстовых файлов. Листинг и редактирование используют SSH-команды; это не полноценный SFTP browser. |
| Git | **частично** | Сервис CLI для status/branch/log/diff/pull/fetch есть, отдельного экрана и разбора ahead/behind пока нет. |
| Health Checks | **план** | Есть модель HTTP/TCP/shell, runner и UI ещё не реализованы. |
| Projects | **частично** | Сущность, SQLite, список серверов проекта и запуск deploy есть. Нет полноценного редактора состава серверов/actions. |
| Производительность | **готово для MVP** | Lazy screens, polling только на видимом сервере, bounded logs/terminal/command output, WAL SQLite, максимум четыре SSH-команды, без blur/тяжёлых анимаций и сторонних зависимостей. Нужен отдельный Instruments-профиль на реальном Intel Mac 4 ГБ перед стабильным релизом. |
| GitHub Actions / релиз | **готово** | `macos-15-intel`, Release x86_64, target 10.15, ZIP, DMG, SHA256, artifact upload и release по тегам `v*`. |

## Критерий релиза

Зелёный GitHub Actions build подтверждает компиляцию текущим Xcode, Intel-only
архитектуру, minimum OS 10.15, корректность bundle и ad-hoc подпись. Финальную
совместимость интерфейса, SSH/Keychain и запуск приложения всё равно следует
один раз проверить на реальном macOS Catalina 10.15.7: GitHub не предоставляет
Catalina runner.
