import AppKit
import Foundation

/// Checks GitHub Releases for a newer `iPaste.zip` and installs it safely.
///
/// Sparkle is intentionally not used: it needs an EdDSA key, an appcast, and
/// a paid Apple certificate. Updates are fetched over HTTPS from this repo
/// and checked against the bundle id and version.
///
/// Replacing or deleting the *running* `.app` unmaps the binary vnode.
/// Later NSXPC / SharedFileList replies then SIGBUS (`KERN_MEMORY_ERROR`,
/// "backing vnode was force unmounted") — the failure iReader hit. This
/// updater:
/// 1. Never touches the live bundle until the process has fully exited.
/// 2. Installs into `/Applications` (or `~/Applications`) when the current
///    bundle lives in a temp or App Translocation location.
/// 3. Starts the helper with `nohup` so `exit(0)` cannot kill it.
/// 4. Keeps the CI signature. It does not ad-hoc re-sign, which would mint a
///    new cdhash and drop Input Monitoring TCC on every update.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let owner = "BianYanhui"
    static let repo = "iPaste"
    static let assetName = "iPaste.zip"
    static let expectedBundleID = "io.github.bianyanhui.iPaste"
    static let autoCheckKey = "iPaste.autoCheckForUpdates"
    static let lastCheckKey = "iPaste.lastUpdateCheck"

    @Published private(set) var isBusy = false
    @Published var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: Self.autoCheckKey) }
    }

    private let session: URLSession
    private var progressAlert: NSAlert?
    private var progressIndicator: NSProgressIndicator?
    private var didScheduleLaunchCheck = false

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
        autoCheckEnabled = UserDefaults.standard.bool(forKey: Self.autoCheckKey)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func checkOnLaunchIfNeeded() {
        guard !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task { await checkForUpdates(interactive: false) }
    }

    func checkForUpdatesFromMenu() {
        Task { await checkForUpdates(interactive: true) }
    }

    func checkForUpdates(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            let current = Self.currentVersion()
            guard Self.isVersion(release.version, newerThan: current) else {
                if interactive {
                    presentInfo(
                        title: "已是最新版本",
                        message: "当前版本 \(current)，最新发布也是 \(release.version)。"
                    )
                }
                return
            }

            let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            var message: String
            if let notes, !notes.isEmpty {
                message = "当前版本 \(current) → \(release.version)\n\n\(Self.plainText(fromMarkdown: notes))"
            } else {
                message = "当前版本 \(current)，可更新到 \(release.version)。"
            }

            let running = Bundle.main.bundleURL
            let installURL = Self.preferredInstallURL(current: running)
            if installURL.standardizedFileURL != running.standardizedFileURL {
                message += "\n\n当前应用位于临时目录，新版本将安装到：\n\(installURL.path)"
            }

            let update = presentChoice(
                title: "发现新版本 \(release.version)",
                message: message + "\n\n更新会先退出 iPaste，等进程结束后再替换应用并重新打开。",
                confirm: "立即更新",
                cancel: "稍后"
            )
            guard update else { return }

            try await downloadAndInstall(release, installURL: installURL, runningURL: running)
        } catch {
            if interactive || !(error is CancellationError) {
                presentError(error)
            }
        }
    }

    struct ReleaseInfo {
        let version: String
        let tagName: String
        let body: String?
        let downloadURL: URL
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iPaste/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw UpdateError.noReleases
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateError.httpStatus(http.statusCode)
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw UpdateError.badResponse
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
              let download = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: download) else {
            throw UpdateError.missingAsset
        }

        return ReleaseInfo(
            version: Self.normalizedVersion(tag),
            tagName: tag,
            body: json["body"] as? String,
            downloadURL: downloadURL
        )
    }

    private func downloadAndInstall(
        _ release: ReleaseInfo,
        installURL: URL,
        runningURL: URL
    ) async throws {
        guard installURL.pathExtension == "app" else {
            throw UpdateError.notInstalled
        }

        let installParent = installURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: installParent.path) {
            try FileManager.default.createDirectory(at: installParent, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: installParent.path) else {
            throw UpdateError.notWritable(installURL.path)
        }

        showProgress(title: "正在下载 iPaste \(release.version)…")
        defer { hideProgress() }

        let (tempURL, response) = try await session.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }

        updateProgress(title: "正在准备安装…")

        let expectedVersion = release.version
        let currentVersion = Self.currentVersion()
        let assetName = Self.assetName
        let expectedBundleID = Self.expectedBundleID
        let staging = try await Task.detached(priority: .userInitiated) {
            try Self.stageDownloadedUpdate(
                tempZip: tempURL,
                expectedVersion: expectedVersion,
                currentVersion: currentVersion,
                assetName: assetName,
                expectedBundleID: expectedBundleID
            )
        }.value

        try await Task.detached(priority: .userInitiated) {
            try Self.launchReplacementScript(
                sourceApp: staging,
                installApp: installURL,
                runningApp: runningURL,
                pid: ProcessInfo.processInfo.processIdentifier
            )
        }.value

        prepareToQuitForUpdate()
        try await Task.sleep(nanoseconds: 400_000_000)
        hideProgress()
        exit(0)
    }

    /// Unzip and validate beside the running bundle. Does not modify it.
    nonisolated private static func stageDownloadedUpdate(
        tempZip: URL,
        expectedVersion: String,
        currentVersion: String,
        assetName: String,
        expectedBundleID: String
    ) throws -> URL {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("iPaste-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zipPath = workDir.appendingPathComponent(assetName)
        if fm.fileExists(atPath: zipPath.path) {
            try fm.removeItem(at: zipPath)
        }
        try fm.moveItem(at: tempZip, to: zipPath)

        let unzipDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try unzip(zipPath, into: unzipDir)

        let newApp = try findAppBundle(in: unzipDir)
        try validateAppBundle(
            newApp,
            expectedVersion: expectedVersion,
            currentVersion: currentVersion,
            expectedBundleID: expectedBundleID
        )

        let staging = fm.temporaryDirectory
            .appendingPathComponent("iPaste-new-\(UUID().uuidString).app", isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: newApp, to: staging)
        try? fm.removeItem(at: workDir)
        return staging
    }

    private func prepareToQuitForUpdate() {
        NotificationCenter.default.post(name: .iPasteWillQuitForUpdate, object: nil)
        CopyChordMonitor.shared.stop()
        CritOverlayController.shared.hide()
        for window in NSApp.windows {
            window.orderOut(nil)
        }
    }

    nonisolated private static func unzip(_ zip: URL, into directory: URL) throws {
        let result = try run("/usr/bin/ditto", arguments: ["-x", "-k", zip.path, directory.path])
        guard result == 0 else { throw UpdateError.unzipFailed }
    }

    nonisolated private static func findAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let direct = contents.first(where: { $0.lastPathComponent == "iPaste.app" }) {
            return direct
        }
        for item in contents where item.hasDirectoryPath {
            let nested = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            if let app = nested.first(where: { $0.lastPathComponent == "iPaste.app" }) {
                return app
            }
        }
        throw UpdateError.missingAppInZip
    }

    nonisolated private static func validateAppBundle(
        _ app: URL,
        expectedVersion: String,
        currentVersion: String,
        expectedBundleID: String
    ) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw UpdateError.invalidAppBundle
        }
        guard bundleID == expectedBundleID else {
            throw UpdateError.bundleIDMismatch(bundleID)
        }
        let version = (info["CFBundleShortVersionString"] as? String).map(normalizedVersion)
            ?? expectedVersion
        if isVersion(expectedVersion, newerThan: version) {
            throw UpdateError.versionNotNewer(version)
        }
        if !isVersion(version, newerThan: currentVersion) {
            throw UpdateError.versionNotNewer(version)
        }
        let executable = app.appendingPathComponent("Contents/MacOS/iPaste")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidAppBundle
        }
    }

    static func isEphemeralAppLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") { return true }
        let prefixes = [
            "/private/var/folders/",
            "/var/folders/",
            "/tmp/",
            "/private/tmp/",
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    static func preferredInstallURL(current: URL) -> URL {
        guard isEphemeralAppLocation(current) else { return current }

        let systemApps = URL(fileURLWithPath: "/Applications/iPaste.app")
        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return systemApps
        }

        let homeAppsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: homeAppsDir, withIntermediateDirectories: true)
        return homeAppsDir.appendingPathComponent("iPaste.app", isDirectory: true)
    }

    /// Waits for this PID to exit, then renames the new app into place.
    /// Paths travel in the environment so spaces never enter the script text.
    nonisolated private static func launchReplacementScript(
        sourceApp: URL,
        installApp: URL,
        runningApp: URL,
        pid: Int32
    ) throws {
        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory
            .appendingPathComponent("iPaste-install-\(UUID().uuidString).sh")

        let script = #"""
        #!/bin/bash
        set -e
        PID="${IPASTE_UPDATER_PID:?}"
        SRC="${IPASTE_UPDATER_SRC:?}"
        DST="${IPASTE_UPDATER_DST:?}"
        RUNNING="${IPASTE_UPDATER_RUNNING:?}"
        LOG="$HOME/Library/Logs/iPaste-update.log"
        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "$(date) updater start pid=$PID"
        echo "SRC=$SRC"
        echo "DST=$DST"
        echo "RUNNING=$RUNNING"

        waited=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          sleep 0.25
          waited=$((waited + 1))
          if [ "$waited" -gt 240 ]; then
            echo "$(date) timeout waiting for pid $PID"
            exit 1
          fi
        done
        while /bin/ps -p "$PID" -o pid= >/dev/null 2>&1; do
          sleep 0.25
        done
        # Let NSXPC / vnode teardown finish. Replacing earlier SIGBUS-crashes.
        sleep 1.5

        if [ ! -d "$SRC" ]; then
          echo "$(date) missing staged app: $SRC"
          exit 1
        fi

        # Drop quarantine only. Do not ad-hoc re-sign: a new cdhash would
        # drop Input Monitoring TCC. The zip is already signed in CI.
        /usr/bin/xattr -dr com.apple.quarantine "$SRC" || true

        DST_DIR="$(dirname "$DST")"
        DST_BASE="$(basename "$DST")"
        STAGED="$DST_DIR/$DST_BASE.new"
        BACKUP="$DST_DIR/$DST_BASE.old"
        /bin/rm -rf "$STAGED" "$BACKUP"
        /usr/bin/ditto "$SRC" "$STAGED"
        /usr/bin/xattr -dr com.apple.quarantine "$STAGED" || true
        /usr/bin/codesign --verify --verbose=2 "$STAGED" || echo "$(date) warning: staged signature did not verify"

        if [ -e "$DST" ]; then
          /bin/mv "$DST" "$BACKUP"
        fi
        /bin/mv "$STAGED" "$DST"

        /usr/bin/open "$DST"
        sleep 0.8

        /bin/rm -rf "$BACKUP" "$SRC"
        if [ "$RUNNING" != "$DST" ] && [ -e "$RUNNING" ]; then
          /bin/rm -rf "$RUNNING" || true
        fi
        /bin/rm -f "$0"
        echo "$(date) updater done"
        """#

        guard let scriptData = script.data(using: .utf8) else {
            throw UpdateError.helperFailed
        }
        try scriptData.write(to: scriptURL, options: .atomic)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path
        )
        guard fm.isExecutableFile(atPath: scriptURL.path) else {
            throw UpdateError.helperFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "/usr/bin/nohup /bin/bash \"$1\" >/dev/null 2>&1 &",
            "--",
            scriptURL.path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["IPASTE_UPDATER_PID"] = String(pid)
        env["IPASTE_UPDATER_SRC"] = sourceApp.path
        env["IPASTE_UPDATER_DST"] = installApp.path
        env["IPASTE_UPDATER_RUNNING"] = runningApp.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UpdateError.helperFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.helperFailed
        }
    }

    @discardableResult
    nonisolated private static func run(_ launchPath: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func currentVersion() -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return normalizedVersion(raw)
    }

    nonisolated static func normalizedVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s.removeFirst()
        }
        return s
    }

    nonisolated static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = numericParts(lhs)
        let b = numericParts(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func numericParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { part in
                let digits = part.prefix(while: { $0.isNumber })
                return Int(digits) ?? 0
            }
    }

    static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```"#, ""),
            (#"`([^`]*)`"#, "$1"),
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"^#{1,6}\s+"#, ""),
            (#"^\s*[-*+]\s+"#, "• "),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"\*([^*]+)\*"#, "$1"),
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            }
        }
        let maxLen = 1200
        if text.count > maxLen {
            let idx = text.index(text.startIndex, offsetBy: maxLen)
            text = String(text[..<idx]) + "…"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @discardableResult
    private func presentChoice(title: String, message: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if case .noReleases? = error as? UpdateError {
            alert.addButton(withTitle: "打开 Releases 页面")
            if alert.runModal() == .alertSecondButtonReturn {
                if let url = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }
        alert.runModal()
    }

    private func showProgress(title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "请稍候。iPaste 会在退出之后才替换应用。"
        alert.alertStyle = .informational

        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        alert.accessoryView = indicator

        progressIndicator = indicator
        progressAlert = alert

        let window = alert.window
        window.level = .floating
        alert.layout()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateProgress(title: String) {
        progressAlert?.messageText = title
        progressIndicator?.isIndeterminate = true
        progressIndicator?.startAnimation(nil)
    }

    private func hideProgress() {
        progressAlert?.window.orderOut(nil)
        progressAlert = nil
        progressIndicator = nil
    }
}

enum UpdateError: LocalizedError, Sendable {
    case noReleases
    case missingAsset
    case badResponse
    case httpStatus(Int)
    case notInstalled
    case notWritable(String)
    case unzipFailed
    case missingAppInZip
    case invalidAppBundle
    case bundleIDMismatch(String)
    case versionNotNewer(String)
    case helperFailed

    var errorDescription: String? {
        switch self {
        case .noReleases:
            return "还没有任何 GitHub Release。打上 v* 标签后，构建会附上 iPaste.zip。"
        case .missingAsset:
            return "最新 Release 中没有找到 iPaste.zip。"
        case .badResponse:
            return "无法解析 GitHub 的响应。"
        case .httpStatus(let code):
            return "GitHub 返回了 HTTP \(code)。"
        case .notInstalled:
            return "当前不是从 .app 包运行。请先把 iPaste.app 放到「应用程序」后再更新。"
        case .notWritable(let path):
            return "没有权限写入：\n\(path)\n请把应用放到你的「应用程序」文件夹后再试。"
        case .unzipFailed:
            return "解压更新包失败。"
        case .missingAppInZip:
            return "更新包里没有找到 iPaste.app。"
        case .invalidAppBundle:
            return "更新包中的应用无效。"
        case .bundleIDMismatch(let id):
            return "更新包的 Bundle ID（\(id)）与当前应用不一致，已取消安装。"
        case .versionNotNewer(let v):
            return "下载到的版本（\(v)）不比当前版本新，已取消安装。"
        case .helperFailed:
            return "无法启动安装脚本。请从 GitHub Releases 手动下载，先退出 iPaste 再替换。"
        }
    }
}
