# Проверка по ТЗ

Дата проверки: 2026-10-02.

Обозначения: **готово** — есть рабочая реализация в текущем проекте;
**частично** — основа работает, но не все подпункты ТЗ реализованы;
**план** — пока только модель/заготовка либо реализации нет.

| Раздел | Статус | Что есть / чего не хватает |
|---|---|---|
| macOS 10.15, Intel, AppKit | **готово** | Deployment target 10.15 в проекте и Info.plist; `ARCHS=x86_64`; AppKit без SwiftUI/Electron. CI проверяет архитектуру и `minos` готового Mach-O. |
| Servers | **готово** | CRUD, группы, избранное, password/key auth, Test Connection. |
| Keychain / SQLite | **готово** | Секреты хранятся в Keychain; SQLite содержит только `secret_id`. Askpass получает секрет только в памяти короткоживущего SSH-процесса и не пишет его во временный файл. |
| SSH | **готово** | Системный OpenSSH, ControlMaster/ControlPath, переиспользование соединений, лимит параллельных команд, timeout, асинхронный UI. |
| Terminal | **готово** | Несколько независимых SSH-вкладок, сохранение вывода при переключении, постоянная история команд со стрелками, избранные команды, локальный `clear`, общий ControlMaster, resize через `stty`, reconnect, copy/paste и ограниченный буфер. |
| Dashboard сервера | **готово** | Online/offline, hostname, OS, uptime, CPU/RAM/disk/load/network, наличие Docker/systemd. |
| Docker | **готово** | Список, CPU/RAM, uptime, restart count, ports/image и Start/Stop/Restart/Logs/Live Logs/интерактивный Shell/Inspect/Stats/Remove; compose ps/pull/up/down/restart/logs/build. Вкладка скрывается, если Docker недоступен. |
| systemd | **готово** | Список и Start/Stop/Restart/Status/Enable/Disable/Logs/Live Logs через `journalctl`. |
| Logs | **готово** | Автопоиск systemd-служб, Docker-контейнеров и читаемых log-файлов с выбором из списка; ручная команда, настоящий stream, pause/resume, clear, search, level filter, copy, timestamps, ограничение количества строк. |
| Monitoring | **готово** | Настраиваемые интервалы CPU/RAM, disk и Docker, один SSH round-trip, остановка на скрытом экране, SQLite history/pruning и нативные графики 15m/1h/24h. |
| Problems | **готово** | Offline, disk, RAM, failed systemd и Docker restart count; строки проблем содержат быстрые Inspect/Restart действия с подтверждением. |
| Custom Actions | **готово** | Command/Poll/Stream/Check/Group, interval, working directory, environment, confirmation, display type, stop_on_error, pin в Quick Actions. Poll/Check не запускают новый цикл, пока предыдущий не завершился. |
| Quick Actions | **готово** | Пользовательские закреплённые действия, включая обязательное подтверждение опасных действий. |
| Deploy | **готово** | Сохраняемые workflows в SQLite, редактор server/working directory/steps/options, статус каждого шага, confirmation, stop on error и bounded output. Rollback создаётся отдельным пользовательским Action. |
| Files / SFTP | **готово** | Ленивое дерево каталогов через NSOutlineView, выбор и drag-and-drop файлов и папок с рекурсивной загрузкой в выбранный удалённый каталог, upload/download с прогрессом и ограниченной памятью, rename/delete/mkdir и редактор UTF-8 файлов до 10 MB. |
| Git | **готово** | Автопоиск репозиториев в типовых каталогах сервера и выбор пути из списка; status, текущая ветка, последний commit, ahead/behind, modified files, branch, log, diff, pull и fetch. |
| Health Checks | **готово** | Сохраняемые HTTP/TCP/shell проверки; любой HTTP-ответ, включая 403, считается доступным сервисом, сетевые ошибки показываются полностью, HTTPS проверяется с Linux-сервера через curl, есть цветной индикатор, latency и прокручиваемый результат. |
| Локализация | **готово** | Переключение English / Русский из меню приложения; настройка сохраняется и применяется ко всем основным экранам и диалогам. |
| Projects | **готово** | CRUD, выбор серверов и Actions проекта, SQLite и отдельные сохраняемые deploy workflows. |
| Производительность | **готово для MVP** | Lazy screens, polling только на видимом сервере, bounded logs/terminal/command output, WAL SQLite, максимум четыре SSH-команды, без blur/тяжёлых анимаций и сторонних зависимостей. Нужен отдельный Instruments-профиль на реальном Intel Mac 4 ГБ перед стабильным релизом. |
| Безопасные действия | **готово** | Терминал предупреждает перед опасными командами; остановка/перезапуск Docker и systemd, disable, удаление и другие разрушающие действия требуют подтверждения. |
| Адаптивность | **готово** | Основная навигация компактная, длинные панели действий разбиты на строки, подписи обрезаются корректно; минимальная высота окна уменьшена до 420 pt. |
| GitHub Actions / релиз | **готово** | `macos-15-intel`, Release x86_64, target 10.15, ZIP, DMG, SHA256, artifact upload и release по тегам `v*`; автоматическая и ручная проверка новых GitHub Releases. |

## Критерий релиза

Зелёный GitHub Actions build подтверждает компиляцию текущим Xcode, Intel-only
архитектуру, minimum OS 10.15, корректность bundle и ad-hoc подпись. Финальную
совместимость интерфейса, SSH/Keychain и запуск приложения всё равно следует
один раз проверить на реальном macOS Catalina 10.15.7: GitHub не предоставляет
Catalina runner.
