import Cocoa

struct AppPreferences: Codable, Equatable {
    var cpuRamPollSeconds: Int = 5
    var diskPollSeconds: Int = 30
    var dockerPollSeconds: Int = 8
    var logBufferMaxLines: Int = 10_000
    var monitoringHistoryHours: Int = 24
    var maxConcurrentSSHCommands: Int = 4
    var selectedSidebarItem: String = "servers"
}

enum InterfaceLanguage: String, CaseIterable {
    case english
    case russian

    var title: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
}

enum L10n {
    private static let defaultsKey = "MaosDevOps.interfaceLanguage"

    static var language: InterfaceLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = InterfaceLanguage(rawValue: raw) else { return .english }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static func text(_ english: String) -> String {
        guard language == .russian else { return english }
        return russian[english] ?? english
    }

    /// Applies translations to ordinary AppKit controls created in code. This
    /// keeps Catalina compatibility and lets every screen share one language
    /// setting without storyboards or macOS-version-specific APIs.
    static func apply(to root: NSView) {
        if let popup = root as? NSPopUpButton {
            for item in popup.itemArray { item.title = text(item.title) }
        } else if let button = root as? NSButton {
            button.title = text(button.title)
        } else if let segmented = root as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                segmented.setLabel(text(segmented.label(forSegment: index) ?? ""), forSegment: index)
            }
        } else if let field = root as? NSTextField {
            field.stringValue = text(field.stringValue)
            if let placeholder = field.placeholderString {
                field.placeholderString = text(placeholder)
            }
        } else if let table = root as? NSTableView {
            for column in table.tableColumns { column.title = text(column.title) }
        }
        root.subviews.forEach { apply(to: $0) }
    }

    private static let russian: [String: String] = [
        "Dashboard": "Панель",
        "Servers": "Серверы",
        "Projects": "Проекты",
        "Actions": "Действия",
        "Monitoring": "Мониторинг",
        "Notifications": "Уведомления",
        "Custom command": "Своя команда",
        "Server offline": "Сервер недоступен",
        "Disk": "Диск",
        "Succeeded": "Успешно",
        "Any result": "Любой результат",
        "Test notification": "Тестовое уведомление",
        "Create macOS notifications for server monitoring, health checks, actions, or a custom SSH command.": "Создавайте уведомления macOS для мониторинга сервера, проверок, действий или своей SSH-команды.",
        "On": "Вкл",
        "Condition": "Условие",
        "Health check unavailable": "Проверка недоступна",
        "Action unavailable": "Действие недоступно",
        "Add a server first": "Сначала добавьте сервер",
        "Enabled": "Включено",
        "Monitoring event": "Событие мониторинга",
        "Threshold": "Порог",
        "Check / action": "Проверка / действие",
        "Trigger result": "Результат-триггер",
        "Custom type": "Свой тип",
        "Trigger command": "Команда-триггер",
        "Notification text": "Текст уведомления",
        "Cooldown, sec": "Пауза между уведомлениями, сек",
        "Notify when recovered": "Уведомлять о восстановлении",
        "Test notification": "Тестовое уведомление",
        "Server is not reachable": "Сервер недоступен",
        "Server is reachable again": "Сервер снова доступен",
        "available again": "снова доступно",
        "Condition returned to normal": "Состояние вернулось в норму",
        "Action completed successfully": "Действие выполнено успешно",
        "Overview": "Обзор",
        "Terminal": "Терминал",
        "Services": "Службы",
        "Logs": "Журналы",
        "Files": "Файлы",
        "Health": "Проверки",
        "← Servers": "← Серверы",
        "+ Tab": "+ Вкладка",
        "Close Tab": "Закрыть вкладку",
        "Reconnect": "Переподключить",
        "Favorite commands": "Избранные команды",
        "Run Favorite": "Запустить избранную",
        "Add Favorite": "Добавить в избранное",
        "Remove": "Удалить",
        "Close": "Закрыть",
        "Send": "Отправить",
        "Command — Enter to send": "Команда — Enter для отправки",
        "Go": "Перейти",
        "Home": "Домой",
        "Reload": "Обновить",
        "New Folder": "Новая папка",
        "Upload…": "Загрузить…",
        "Upload": "Загрузить",
        "Download…": "Скачать…",
        "Rename": "Переименовать",
        "Delete": "Удалить",
        "Edit": "Изменить",
        "Name": "Название",
        "Size": "Размер",
        "Save": "Сохранить",
        "Scan": "Найти",
        "Status": "Статус",
        "Branches": "Ветки",
        "History": "История",
        "Changes": "Изменения",
        "Fetch": "Получить",
        "Pull": "Обновить",
        "Repositories will be detected automatically.": "Репозитории будут найдены автоматически.",
        "Searching repositories…": "Поиск репозиториев…",
        "Searching common folders on the server…": "Поиск в типовых каталогах сервера…",
        "Select a repository or enter its absolute path.": "Выберите репозиторий или укажите абсолютный путь.",
        "Select a repository first.": "Сначала выберите репозиторий.",
        "Working tree clean": "Нет локальных изменений",
        "Check the selected repository path and SSH permissions.": "Проверьте путь к репозиторию и права SSH.",
        "Maos DevOps searches common server folders for Git repositories. Select one below, or enter a path manually.": "Maos DevOps ищет Git-репозитории в типовых каталогах сервера. Выберите найденный вариант или укажите путь вручную.",
        "Enter an absolute repository path in the field above, then press Status.": "Введите абсолютный путь к репозиторию и нажмите «Статус».",
        "Repository scan failed": "Не удалось найти репозитории",
        "No repositories found — enter a path below": "Репозитории не найдены — укажите путь ниже",
        "Searching log sources…": "Поиск источников журналов…",
        "Selected source or a custom value": "Выбранный источник или своё значение",
        "Start": "Показать",
        "Live": "В реальном времени",
        "File": "Файл",
        "Command": "Команда",
        "Enter a command below": "Введите команду ниже",
        "No sources found — enter one below": "Источники не найдены — укажите вручную",
        "Log sources are detected automatically. Choose a type and an item, or enter a custom service, container, file path or command.": "Источники журналов определяются автоматически. Выберите тип и источник либо укажите службу, контейнер, файл или команду вручную.",
        "Pause": "Пауза",
        "Resume": "Продолжить",
        "Clear": "Очистить",
        "Copy": "Копировать",
        "Auto-scroll": "Автопрокрутка",
        "Health Checks": "Проверки доступности",
        "Add": "Добавить",
        "Run Now": "Проверить сейчас",
        "Type": "Тип",
        "Target": "Адрес",
        "Full result": "Полный результат",
        "Select a health check to see the complete result.": "Выберите проверку, чтобы увидеть полный результат.",
        "Checking…": "Проверка…",
        "Healthy": "Доступно",
        "Failed": "Ошибка",
        "Not checked yet": "Ещё не проверено",
        "Run": "Запустить",
        "Stop": "Остановить",
        "Refresh": "Обновить",
        "Restart": "Перезапустить",
        "Shell": "Консоль",
        "Compose…": "Compose…",
        "Custom Actions": "Пользовательские действия",
        "Add Action": "Добавить действие",
        "Save Settings": "Сохранить настройки",
        "Server Monitoring": "Мониторинг сервера",
        "CPU / RAM interval, sec": "Интервал CPU / RAM, сек",
        "Disk interval, sec": "Интервал диска, сек",
        "Docker interval, sec": "Интервал Docker, сек",
        "Maximum log lines": "Максимум строк журнала",
        "History, hours": "История, часы",
        "Problems": "Проблемы",
        "Quick Actions": "Быстрые действия",
        "No problems detected": "Проблем не обнаружено",
        "Pin Custom Actions to show them here.": "Закрепите пользовательские действия, чтобы видеть их здесь.",
        "Add Server": "Добавить сервер",
        "Server": "Сервер",
        "Test Connection": "Проверить подключение",
        "Password": "Пароль",
        "SSH Key": "SSH-ключ",
        "Leave blank to keep existing secret": "Оставьте пустым, чтобы сохранить текущий секрет",
        "Password or key passphrase": "Пароль или кодовая фраза ключа",
        "Add Project": "Добавить проект",
        "Deploy Workflows…": "Сценарии развёртывания…",
        "Project name": "Название проекта",
        "Notes": "Заметки",
        "Steps — one command per line": "Шаги — одна команда на строку",
        "Working directory": "Рабочий каталог",
        "Run Deploy": "Запустить развёртывание",
        "URL / host:port / command": "URL / хост:порт / команда",
        "Interval, sec": "Интервал, сек",
        "Cancel": "Отмена",
        "About Maos DevOps": "О Maos DevOps",
        "Check for Updates…": "Проверить обновления…",
        "Language": "Язык",
        "Hide Maos DevOps": "Скрыть Maos DevOps",
        "Hide Others": "Скрыть остальные",
        "Show All": "Показать все",
        "Quit Maos DevOps": "Завершить Maos DevOps",
        "Undo": "Отменить",
        "Redo": "Повторить",
        "Cut": "Вырезать",
        "Paste": "Вставить",
        "Select All": "Выбрать всё",
        "Window": "Окно",
        "Minimize": "Свернуть",
        "Zoom": "Масштаб",
        "Show Maos DevOps Window": "Показать окно Maos DevOps",
        "Bring All to Front": "Все окна на передний план"
    ]
}
