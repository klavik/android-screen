import Foundation
import AppKit
import SwiftUI

private enum ScreenState {
    case idle
    case checking
    case ready
    case streaming
    case failed

    var title: String {
        switch self {
        case .idle: return "Не подключено"
        case .checking: return "Подключаемся…"
        case .ready: return "Устройство доступно"
        case .streaming: return "Трансляция запущена"
        case .failed: return "Ошибка подключения"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .checking: return .orange
        case .ready, .streaming: return .green
        case .failed: return .red
        }
    }
}

private struct AppSettings: Codable {
    var ip: String
    var port: String
    var scrcpyPath: String
    // nil means a setting saved by Android Screen 2.1 or older.
    var useBundledScrcpy: Bool?
    var autoDetectOnLaunch: Bool?
}

private struct CommandResult {
    var code: Int32
    var output: String
}

private final class AndroidScreenModel: ObservableObject {
    @Published var ip: String = ""
    @Published var port: String = "5555"
    @Published var scrcpyPath: String = ""
    @Published var state: ScreenState = .idle
    @Published var detail: String = "Ищем подключённое Android-устройство через ADB…"
    @Published var isWorking: Bool = false
    @Published var isStreaming: Bool = false
    @Published var autoDetectOnLaunch: Bool = true

    private let fileManager = FileManager.default
    private let folderURL: URL
    private let settingsURL: URL
    private let legacyURL: URL
    private let logsURL: URL
    private let sessionURL: URL
    private var mirrorProcess: Process?
    private var sessionOutput: FileHandle?
    private var stoppingByUser = false
    private var attemptedStartupDetection = false
    // Last Wi-Fi ADB endpoint confirmed by a real shell round trip.
    // Display a ready button only while the configured address still matches it.
    private var lastVerifiedEndpoint: String?

    var canStartImmediately: Bool {
        let configuredIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedPath = (scrcpyPath as NSString).expandingTildeInPath
        return state == .ready && !isWorking && !isStreaming &&
            Self.isValidIPv4(configuredIP) && Self.isValidPort(configuredPort) &&
            fileManager.isExecutableFile(atPath: selectedPath) &&
            lastVerifiedEndpoint == "\(configuredIP):\(configuredPort)"
    }

    init() {
        folderURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Android Screen", isDirectory: true)
        settingsURL = folderURL.appendingPathComponent("settings.json")
        legacyURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Huawei Screen/device.txt")
        logsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Android Screen", isDirectory: true)
        sessionURL = logsURL.appendingPathComponent("last-session.log")
        restoreSettings()
    }

    private static var bundledScrcpyPath: String? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let path = base.appendingPathComponent("Tools/scrcpy/scrcpy").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static var bundledADBPath: String? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let path = base.appendingPathComponent("Tools/platform-tools/adb").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var isUsingBundledScrcpy: Bool {
        guard let path = Self.bundledScrcpyPath else { return false }
        return (scrcpyPath as NSString).expandingTildeInPath == path
    }

    func useBundledScrcpy() {
        guard let path = Self.bundledScrcpyPath else {
            setError("Встроенный scrcpy отсутствует. Повтори установку Android Screen.")
            return
        }
        scrcpyPath = path
        _ = saveSettings()
    }

    private func restoreSettings() {
        // Keep new settings if present; otherwise import old Huawei Screen 2.x settings.
        let oldFolder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Huawei Screen", isDirectory: true)
        let oldSettings = oldFolder.appendingPathComponent("settings.json")
        for candidate in [settingsURL, oldSettings] {
            if let data = try? Data(contentsOf: candidate),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                ip = settings.ip
                port = settings.port
                autoDetectOnLaunch = settings.autoDetectOnLaunch ?? true
                // On upgrading from 2.1, switch to the bundled runtime by default.
                // Preserve a custom path explicitly selected in 2.2 or newer.
                if settings.useBundledScrcpy != false,
                   let bundledPath = Self.bundledScrcpyPath {
                    scrcpyPath = bundledPath
                } else {
                    scrcpyPath = settings.scrcpyPath
                }
                return
            }
        }

        // Version 1.0 saved the whole endpoint in device.txt.
        if let oldEndpoint = try? String(contentsOf: legacyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let colon = oldEndpoint.lastIndex(of: ":") {
            let oldIP = String(oldEndpoint[..<colon])
            let oldPort = String(oldEndpoint[oldEndpoint.index(after: colon)...])
            if Self.isValidIPv4(oldIP), Self.isValidPort(oldPort) {
                ip = oldIP
                port = oldPort
            }
        }

        scrcpyPath = Self.findInitialScrcpy() ?? ""
    }

    private static func findInitialScrcpy() -> String? {
        if let bundledPath = bundledScrcpyPath { return bundledPath }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Documents/scrcpy-macos-aarch64-v5.0.1/scrcpy",
            home + "/Documents/scrcpy-macos-x86_64-v5.0.1/scrcpy",
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy"
        ]
        if let matched = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return matched
        }
        for root in [home + "/Documents", home + "/Downloads", home + "/Desktop"] {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { continue }
            for name in items.sorted().reversed() where name.hasPrefix("scrcpy-macos-") {
                let path = url.appendingPathComponent(name).appendingPathComponent("scrcpy").path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func isValidIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }

    private static func isValidPort(_ value: String) -> Bool {
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let number = Int(value) else { return false }
        return (1...65535).contains(number)
    }

    private func validate() -> String? {
        let newIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPath = (scrcpyPath as NSString).expandingTildeInPath
        if !newIP.isEmpty && !Self.isValidIPv4(newIP) { return "Проверь IP-адрес устройства (например, 192.168.1.116)." }
        if !Self.isValidPort(newPort) { return "Порт должен быть числом от 1 до 65535." }
        if !fileManager.isExecutableFile(atPath: newPath) {
            return "Не найден исполняемый файл scrcpy. Укажи его через кнопку «Выбрать…»."
        }
        return nil
    }

    private var endpoint: String { "\(ip):\(port)" }

    @discardableResult
    func saveSettings() -> Bool {
        if let reason = validate() {
            setError(reason)
            return false
        }
        ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        scrcpyPath = (scrcpyPath as NSString).expandingTildeInPath
        let settings = AppSettings(ip: ip, port: port, scrcpyPath: scrcpyPath,
                                   useBundledScrcpy: isUsingBundledScrcpy,
                                   autoDetectOnLaunch: autoDetectOnLaunch)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(settings)
            try bytes.write(to: settingsURL, options: .atomic)
            if !isStreaming && !isWorking {
                if canStartImmediately {
                    detail = "Устройство доступно по ADB: \(endpoint). Можно начать трансляцию."
                } else {
                    state = .idle
                    detail = ip.isEmpty
                        ? "Настройки сохранены. Подключи устройство через USB или укажи IP."
                        : "Настройки сохранены: \(endpoint)"
                }
            }
            return true
        } catch {
            setError("Не удалось сохранить настройки: \(error.localizedDescription)")
            return false
        }
    }

    func chooseScrcpy() {
        let picker = NSOpenPanel()
        picker.title = "Выбери исполняемый файл scrcpy"
        picker.message = "По умолчанию используется встроенный scrcpy. Здесь можно выбрать свою версию."
        picker.prompt = "Выбрать"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        let previous = (scrcpyPath as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: previous) {
            picker.directoryURL = URL(fileURLWithPath: previous).deletingLastPathComponent()
        }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        scrcpyPath = url.path
        _ = saveSettings()
    }

    func revealLogFolder() {
        do {
            try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(logsURL)
        } catch {
            setError("Не удалось открыть папку журналов: \(error.localizedDescription)")
        }
    }

    private func setError(_ message: String) {
        lastVerifiedEndpoint = nil
        state = .failed
        detail = message
    }

    private func findADB(scrcpy: String) -> String? {
        // Always prefer the application-local ADB, even with a custom scrcpy.
        if let bundledPath = Self.bundledADBPath { return bundledPath }
        let sibling = URL(fileURLWithPath: scrcpy).deletingLastPathComponent()
            .appendingPathComponent("adb").path
        let home = NSHomeDirectory()
        let candidates = [
            sibling,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/local/bin/adb",
            home + "/Library/Android/sdk/platform-tools/adb",
            home + "/platform-tools/adb"
        ]
        if let result = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return result
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/adb"
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private static func runADB(_ adb: String, _ args: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = args
        // Using a temporary file avoids a Pipe deadlock if ADB launches its server.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-screen-adb-" + UUID().uuidString + ".log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return CommandResult(code: -1, output: "Не удалось создать временный журнал ADB.")
        }
        defer { handle.closeFile() }
        task.standardOutput = handle
        task.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do {
            try task.run()
            // All callers execute off the UI thread.
            if finished.wait(timeout: .now() + 12) == .timedOut {
                if task.isRunning { task.terminate() }
                return CommandResult(code: -2, output: "Истекло время ожидания ответа ADB (12 секунд).")
            }
            handle.synchronizeFile()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            return CommandResult(code: task.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(code: -1, output: error.localizedDescription)
        }
    }

    private static func wifiProbe(adb: String, endpoint: String) -> Bool {
        let result = runADB(adb, ["-s", endpoint, "shell", "echo", "ANDROID_SCREEN_READY"])
        return result.code == 0 &&
            result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ANDROID_SCREEN_READY"
    }

    private static func makeConnection(adb: String, endpoint: String) -> (Bool, String) {
        if wifiProbe(adb: adb, endpoint: endpoint) {
            return (true, "ADB по Wi-Fi доступен: \(endpoint)")
        }
        let connectResult = runADB(adb, ["connect", endpoint])
        if wifiProbe(adb: adb, endpoint: endpoint) {
            return (true, "Подключено к \(endpoint)")
        }
        let output = connectResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = output.isEmpty ? "Устройство не ответило по Wi-Fi." : output
        return (false, "Не удалось подключиться к \(endpoint). \(why) Проверь Wi-Fi и режим ADB TCP/IP на Android-устройстве.")
    }

    func checkConnection() {
        performConnection(openMirror: false)
    }

    func startMirroring() {
        performConnection(openMirror: true)
    }

    private func performConnection(openMirror: Bool) {
        guard !isWorking && !isStreaming else { return }
        guard saveSettings() else { return }
        guard Self.isValidIPv4(ip) else {
            setError("IP устройства пока не известен. Используй поиск ADB или подключение через USB.")
            return
        }
        guard let adb = findADB(scrcpy: scrcpyPath) else {
            setError("Не найден adb. Повтори установку Android Screen: установщик автоматически добавит встроенный adb.")
            return
        }
        let savedEndpoint = endpoint
        let selectedScrcpy = scrcpyPath
        state = .checking
        detail = "Проверяем ADB по Wi-Fi: \(savedEndpoint)"
        isWorking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (success, information) = Self.makeConnection(adb: adb, endpoint: savedEndpoint)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isWorking = false
                if success {
                    self.lastVerifiedEndpoint = savedEndpoint
                    self.state = .ready
                    self.detail = information
                    if openMirror {
                        self.launchScrcpy(binary: selectedScrcpy, adb: adb, endpoint: savedEndpoint)
                    }
                } else {
                    self.setError(information)
                }
            }
        }
    }

    private func launchScrcpy(binary: String, adb: String, endpoint: String) {
        do {
            try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
            _ = fileManager.createFile(atPath: sessionURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: sessionURL)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: binary)
            task.currentDirectoryURL = URL(fileURLWithPath: binary).deletingLastPathComponent()
            task.arguments = ["-s", endpoint]
            var environment = ProcessInfo.processInfo.environment
            let adbDirectory = URL(fileURLWithPath: adb).deletingLastPathComponent().path
            environment["PATH"] = adbDirectory + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" +
                (environment["PATH"] ?? "")
            environment["ADB"] = adb
            let serverFile = task.currentDirectoryURL!.appendingPathComponent("scrcpy-server").path
            if fileManager.fileExists(atPath: serverFile) {
                environment["SCRCPY_SERVER_PATH"] = serverFile
            }
            task.environment = environment
            task.standardOutput = output
            task.standardError = output
            task.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.sessionOutput?.closeFile()
                    self.sessionOutput = nil
                    self.mirrorProcess = nil
                    self.isStreaming = false
                    self.isWorking = false
                    let logText = (try? String(contentsOf: self.sessionURL, encoding: .utf8)) ?? ""
                    if self.stoppingByUser {
                        self.stoppingByUser = false
                        self.state = .ready
                        self.detail = "Трансляция остановлена. Можно подключиться повторно."
                    } else if finished.terminationStatus == 0 &&
                                !logText.contains("WARN: Device disconnected") &&
                                !logText.contains("ERROR:") {
                        self.state = .ready
                        self.detail = "Трансляция завершена. Можно подключиться повторно."
                    } else {
                        self.setError("Трансляция оборвалась (код \(finished.terminationStatus)). Подробности — в журнале.")
                    }
                }
            }
            try task.run()
            mirrorProcess = task
            sessionOutput = output
            isStreaming = true
            state = .streaming
            detail = "scrcpy запущен по Wi-Fi (\(endpoint)). Экран устройства открыт в отдельном окне."
        } catch {
            sessionOutput?.closeFile()
            sessionOutput = nil
            setError("Не удалось запустить scrcpy: \(error.localizedDescription)")
        }
    }

    func stopMirroring() {
        guard let task = mirrorProcess, task.isRunning else { return }
        isWorking = true
        stoppingByUser = true
        detail = "Останавливаем трансляцию…"
        task.terminate()
    }

    // adb devices lists already-associated endpoints, not arbitrary devices on the LAN.
    // Validate a candidate using a real shell round trip before adopting its IP.
    private static func adbDeviceSerials(adb: String) -> (wifi: [String], usb: [String]) {
        let result = runADB(adb, ["devices", "-l"])
        guard result.code == 0 else { return ([], []) }
        var wifi = Set<String>()
        var usb = Set<String>()
        for line in result.output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            if let colon = serial.lastIndex(of: ":") {
                let address = String(serial[..<colon])
                let port = String(serial[serial.index(after: colon)...])
                if isValidIPv4(address) && isValidPort(port) { wifi.insert(serial) }
            } else if !serial.hasPrefix("emulator-") && serial != "List" && serial != "*" {
                usb.insert(serial)
            }
        }
        return (wifi.sorted(), usb.sorted())
    }

    private static func reachableWiFi(adb: String) -> [String] {
        adbDeviceSerials(adb: adb).wifi.filter { wifiProbe(adb: adb, endpoint: $0) }
    }

    func autoDetectConnectedWiFiOnLaunch() {
        guard !attemptedStartupDetection else { return }
        attemptedStartupDetection = true
        guard autoDetectOnLaunch else {
            detail = "Автопоиск выключен. Укажи IP или используй поиск ADB."
            return
        }
        detectConnectedWiFi(automatic: true)
    }

    func detectConnectedWiFi() {
        detectConnectedWiFi(automatic: false)
    }

    private func detectConnectedWiFi(automatic: Bool) {
        guard !isWorking && !isStreaming else { return }
        guard let adb = findADB(scrcpy: scrcpyPath) else {
            setError("Не найден adb. Повтори установку Android Screen, чтобы восстановить встроенный adb.")
            return
        }
        let originalIP = ip
        let originalPort = port
        isWorking = true
        state = .checking
        detail = automatic ? "Автоматически ищем устройство через ADB…" : "Ищем доступные Wi-Fi-устройства ADB…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = Self.reachableWiFi(adb: adb)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isWorking = false
                if connected.isEmpty {
                    self.state = .idle
                    self.detail = "ADB не видит доступных Wi-Fi-устройств. Если это первое подключение или IP изменился, используй блок «Поиск и настройка подключения по Wi-Fi» ниже."
                    return
                }
                if connected.count > 1 {
                    if automatic {
                        self.state = .idle
                        self.detail = "ADB видит несколько Wi-Fi-устройств. Нажми «Найти устройство через ADB», чтобы выбрать нужное."
                    } else {
                        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 310, height: 28), pullsDown: false)
                        menu.addItems(withTitles: connected)
                        let alert = NSAlert()
                        alert.messageText = "Выбери Android-устройство"
                        alert.informativeText = "Найдено несколько доступных Wi-Fi-подключений ADB."
                        alert.addButton(withTitle: "Использовать")
                        alert.addButton(withTitle: "Отмена")
                        alert.accessoryView = menu
                        if alert.runModal() == .alertFirstButtonReturn {
                            self.applyDiscoveredEndpoint(menu.titleOfSelectedItem ?? connected[0], automatic: false,
                                                         originalIP: originalIP, originalPort: originalPort)
                        } else {
                            self.state = .idle
                            self.detail = "Выбор устройства отменён."
                        }
                    }
                    return
                }
                self.applyDiscoveredEndpoint(connected[0], automatic: automatic,
                                             originalIP: originalIP, originalPort: originalPort)
            }
        }
    }

    private func applyDiscoveredEndpoint(_ found: String, automatic: Bool,
                                         originalIP: String, originalPort: String) {
        guard let colon = found.lastIndex(of: ":") else { return }
        let address = String(found[..<colon])
        let detectedPort = String(found[found.index(after: colon)...])
        guard Self.isValidIPv4(address), Self.isValidPort(detectedPort) else {
            setError("ADB вернул некорректный адрес устройства.")
            return
        }
        // Don't discard a manual edit made while the background discovery was running.
        if automatic && (ip != originalIP || port != originalPort) {
            state = .idle
            detail = "Найдено \(found), но введённые тобой настройки оставлены без изменений."
            return
        }
        ip = address
        port = detectedPort
        if saveSettings() {
            lastVerifiedEndpoint = found
            state = .ready
            detail = "Устройство найдено и доступно по ADB: \(found). Адрес сохранён."
        }
    }

    // One-click setup for Android builds without a Wireless debugging toggle.
    // USB must be connected; we do not change the device without an explicit click.
    private static func ipv4FromUSB(adb: String, serial: String) -> String? {
        let commands = [
            ["-s", serial, "shell", "ip", "-4", "addr", "show", "wlan0"],
            ["-s", serial, "shell", "ip", "-4", "route"]
        ]
        let patterns = [#"inet\s+((?:\d{1,3}\.){3}\d{1,3})/"#,
                        #"\bsrc\s+((?:\d{1,3}\.){3}\d{1,3})\b"#]
        for (index, command) in commands.enumerated() {
            let result = runADB(adb, command)
            guard result.code == 0,
                  let regex = try? NSRegularExpression(pattern: patterns[index]) else { continue }
            let output = result.output as NSString
            if let match = regex.firstMatch(in: result.output,
                                            range: NSRange(location: 0, length: output.length)),
               match.range(at: 1).location != NSNotFound {
                let address = output.substring(with: match.range(at: 1))
                if isValidIPv4(address) { return address }
            }
        }
        return nil
    }

    func enableWiFiViaUSB() {
        guard !isWorking && !isStreaming else { return }
        guard let adb = findADB(scrcpy: scrcpyPath) else {
            setError("Встроенный adb не найден. Повтори установку приложения.")
            return
        }
        guard Self.isValidPort(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            setError("Укажи корректный порт (обычно 5555).")
            return
        }
        let requestedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        state = .checking
        detail = "Проверяем USB и определяем Wi-Fi-адрес устройства…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let usb = Self.adbDeviceSerials(adb: adb).usb
            var outcome: String
            var connectedEndpoint: String? = nil
            if usb.isEmpty {
                outcome = "USB-устройство не найдено. Подключи кабель передачи данных, включи отладку по USB и разреши доступ на экране Android."
            } else if usb.count > 1 {
                outcome = "Обнаружено несколько USB-устройств. Отключи лишние устройства и повтори действие."
            } else if let address = Self.ipv4FromUSB(adb: adb, serial: usb[0]) ??
                        (Self.isValidIPv4(enteredIP) ? enteredIP : nil) {
                let result = Self.runADB(adb, ["-s", usb[0], "tcpip", requestedPort])
                if result.code != 0 {
                    outcome = "Не удалось включить ADB TCP/IP: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let endpoint = "\(address):\(requestedPort)"
                    var success = false
                    for _ in 0..<4 {
                        Thread.sleep(forTimeInterval: 1.0)
                        let _ = Self.runADB(adb, ["connect", endpoint])
                        if Self.wifiProbe(adb: adb, endpoint: endpoint) {
                            success = true
                            break
                        }
                    }
                    if success {
                        connectedEndpoint = endpoint
                        outcome = "ADB TCP/IP включён: \(endpoint). Отключи USB и нажми «Проверить соединение». Если связь исчезнет, устройство отключает ADB по Wi-Fi при извлечении кабеля."
                    } else {
                        outcome = "ADB TCP/IP включён для \(endpoint), но подключиться не получилось. Не отключая USB, проверь Wi-Fi на обоих устройствах и попробуй ещё раз."
                    }
                }
            } else {
                outcome = "Не удалось определить Wi-Fi IP через USB. Проверь Wi-Fi на Android или введи его IP вручную в поле выше и повтори активацию."
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isWorking = false
                if let found = connectedEndpoint {
                    self.applyDiscoveredEndpoint(found, automatic: false,
                                                 originalIP: self.ip, originalPort: self.port)
                    self.detail = outcome
                } else {
                    self.setError(outcome)
                }
            }
        }
    }

}

private struct SectionPanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct ScrollableSectionPanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct AndroidScreenView: View {
    @ObservedObject var model: AndroidScreenModel

    private var icon: NSImage? {
        guard let path = Bundle.main.path(forResource: "AndroidScreen", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) {
                if let image = icon {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 66, height: 66)
                } else {
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 36))
                        .frame(width: 66, height: 66)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Android Screen")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Трансляция Android на Mac через scrcpy по Wi-Fi")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                SectionPanel(title: "Подключение") {
                    HStack(spacing: 10) {
                        Circle().fill(model.state.tint)
                            .frame(width: 11, height: 11)
                        Text(model.state.title)
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Text(model.detail)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 80, alignment: .topLeading)
                    Divider()
                    Text("Адрес подключения")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(model.ip):\(model.port)")
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if model.isStreaming {
                        Button(action: model.stopMirroring) {
                            Label("Остановить трансляцию", systemImage: "stop.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                    } else if model.canStartImmediately {
                        Button(action: model.startMirroring) {
                            Label("Начать трансляцию", systemImage: "play.rectangle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                    } else {
                        Button(action: model.startMirroring) {
                            Label("Начать трансляцию", systemImage: "play.rectangle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(model.isWorking)
                    }
                    Button(action: model.checkConnection) {
                        Label("Проверить соединение", systemImage: "wifi")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isWorking || model.isStreaming)
                    Button(action: model.revealLogFolder) {
                        Label("Открыть журналы", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 280)

                VStack(spacing: 16) {
                    SectionPanel(title: "Адрес устройства") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("IP-адрес").font(.caption).foregroundColor(.secondary)
                                TextField("192.168.1.116", text: $model.ip)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Порт").font(.caption).foregroundColor(.secondary)
                                TextField("5555", text: $model.port)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 82)
                            }
                        }
                        .disabled(model.isWorking || model.isStreaming)
                    }

                    SectionPanel(title: "Исполняемый файл scrcpy") {
                        Text("Путь к программе, через которую открывается экран Android-устройства.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("Путь к scrcpy", text: $model.scrcpyPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("Выбрать…", action: model.chooseScrcpy)
                        }
                        .disabled(model.isWorking || model.isStreaming)
                        HStack {
                            Text(model.isUsingBundledScrcpy
                                 ? "Используется встроенный scrcpy"
                                 : "Выбран сторонний scrcpy")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Встроенный", action: model.useBundledScrcpy)
                                .disabled(model.isWorking || model.isStreaming || model.isUsingBundledScrcpy)
                        }
                    }

                    HStack {
                        Spacer()
                        Button(action: { _ = model.saveSettings() }) {
                            Label("Сохранить настройки", systemImage: "square.and.arrow.down")
                        }
                        .disabled(model.isWorking || model.isStreaming)
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }
            }
            ScrollableSectionPanel(title: "Поиск и настройка подключения по Wi-Fi") {
                Text("Два способа подключения. Выбери подходящий — обе кнопки работают без Терминала.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Label("1. Устройство уже подключалось по Wi-Fi", systemImage: "wifi")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Найти среди устройств, к которым ADB уже установил соединение. Если устройство доступно, его IP и порт будут подставлены автоматически. Это не поиск всех устройств в сети.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: model.detectConnectedWiFi) {
                        Label("Найти устройство через ADB", systemImage: "magnifyingglass")
                    }
                    .disabled(model.isWorking || model.isStreaming)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("2. Первое подключение или Wi-Fi-связь потеряна", systemImage: "cable.connector")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Подключи Android к Mac USB-кабелем, включи отладку по USB и разреши доступ. Приложение включит ADB по Wi-Fi, определит IP и проверит соединение.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: model.enableWiFiViaUSB) {
                        Label("Настроить подключение по Wi-Fi через USB", systemImage: "cable.connector")
                    }
                    .disabled(model.isWorking || model.isStreaming)
                }

                Divider()

                Toggle("Автоматически находить доступное ADB-устройство при запуске", isOn: $model.autoDetectOnLaunch)
                    .font(.caption)
                    .disabled(model.isWorking || model.isStreaming)
                Text("Автопоиск проверяет только ранее подключённые ADB-устройства. Если адрес изменился и подключение потеряно, используй настройку через USB.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Пошаговая инструкция первого подключения") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Подключи Mac и Android к одной Wi-Fi-сети.")
                        Text("2. На Android открой настройки разработчика и включи «Отладку по USB». Если раздел скрыт, открой «О телефоне/планшете» и нажми «Номер сборки» семь раз.")
                        Text("3. Подключи Android к Mac USB-кабелем с передачей данных. На Android разреши отладку для этого Mac.")
                        Text("4. Нажми «Настроить подключение по Wi-Fi через USB» выше и дождись подтверждения соединения.")
                        Text("5. Отключи кабель, нажми «Проверить соединение», затем «Начать трансляцию».")
                        Text("Если после отключения кабеля соединение исчезает, проверь настройки отладки и ограничения прошивки устройства.")
                            .foregroundColor(.secondary)
                        Text("Если на Android есть отдельный пункт «Беспроводная отладка», можно настроить сопряжение по коду через adb pair и ввести выданные IP и порт вручную.")
                            .foregroundColor(.secondary)
                        Link("Документация scrcpy", destination: URL(string: "https://github.com/Genymobile/scrcpy")!)
                    }
                    .font(.caption)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Важно: Mac и Android должны находиться в одной Wi-Fi-сети. После перезагрузки Android может понадобиться повторная настройка ADB через USB.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(minWidth: 850, minHeight: 710)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: model.autoDetectConnectedWiFiOnLaunch)
    }
}

@main
struct AndroidScreenApp: App {
    @StateObject private var model = AndroidScreenModel()

    var body: some Scene {
        WindowGroup("Android Screen") {
            AndroidScreenView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
