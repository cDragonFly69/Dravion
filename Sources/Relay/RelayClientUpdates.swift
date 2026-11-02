import SwiftUI
import CryptoKit
import RelayCore

/// Installed and latest versions of the clients Dravion drives, with a one-click upgrade for each (like the app
/// manager in cc-switch). CLIs installed through npm upgrade with npm; DeepSeek Harness downloads its own
/// update feed (checksum verified) and replaces the app; apps without a public feed open their own updater.
@MainActor @Observable final class RelayClientUpdates {
    enum Kind: String, CaseIterable, Identifiable {
        case claude = "Claude Code CLI", codex = "Codex CLI", dsh = "DeepSeek Harness", workbuddy = "WorkBuddy", claudeApp = "Claude 桌面版", openclaw = "OpenClaw（微信 ClawBot）"
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .claude, .claudeApp: return RelayPalette.ember
            case .codex: return RelayPalette.client("Codex")
            case .dsh: return RelayPalette.teal
            case .workbuddy: return RelayPalette.violet
            case .openclaw: return RelayPalette.green
            }
        }
    }
    struct Item: Identifiable {
        var kind: Kind
        var installed: String?
        var latest: String?
        var path: String?
        var problem: String?
        var upgrade: Upgrade?
        var id: String { kind.rawValue }
        var outdated: Bool {
            guard let installed, let latest else { return false }
            return installed.compare(latest, options: .numeric) == .orderedAscending
        }
    }
    enum Upgrade {
        case npm(package: String, npm: String)
        case command(String, [String])
        case feed(app: String, file: URL, sha512: String, version: String)
        case openApp(String)
        var summary: String {
            switch self {
            case .npm(let package, _): return "npm install -g \(package)@latest"
            case .command(let command, let arguments): return ([URL(fileURLWithPath: command).lastPathComponent] + arguments).joined(separator: " ")
            case .feed(_, let file, _, let version): return "下载 \(version)（\(file.lastPathComponent)），校验 sha512 后替换应用"
            case .openApp: return "打开应用，使用应用内更新"
            }
        }
    }

    var items: [Item] = []
    var checking = false
    var working: Kind?
    var log: [Kind: String] = [:]
    @ObservationIgnored private let runner = RelayProcessRunner()

    private static var path: [String] { (RelayEnvironment.child()["PATH"] ?? "").split(separator: ":").map(String.init) }
    private static func which(_ name: String, extra: [String] = []) -> String? {
        (extra + path.map { $0 + "/" + name }).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static func plistVersion(_ app: String) -> String? {
        (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String)
    }

    func check() async {
        checking = true
        defer { checking = false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let npm = Self.which("npm", extra: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"])
        var next: [Item] = []

        for (kind, name, package) in [(Kind.claude, "claude", "@anthropic-ai/claude-code"), (.codex, "codex", "@openai/codex"), (.openclaw, "openclaw", "openclaw")] {
            var item = Item(kind: kind)
            item.path = Self.which(name, extra: kind == .claude ? ["\(home)/.local/bin/claude"] : [])
            async let latest = Self.npmLatest(package)
            if let path = item.path {
                let output = await version(path)
                item.installed = output.version
                if output.version == nil { item.problem = output.error.map { "无法读取版本：" + String($0.prefix(240)) } ?? "无法读取版本" }
            }
            item.latest = await latest
            let resolved = item.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
            if let npm, item.path == nil || resolved.contains("/node_modules/") {
                item.upgrade = .npm(package: package, npm: npm)
            } else if kind == .claude, let path = item.path {
                item.upgrade = .command(path, ["update"])
            }
            next.append(item)
        }

        var dsh = Item(kind: .dsh)
        let dshApp = "/Applications/DeepSeek Harness.app"
        dsh.installed = Self.plistVersion(dshApp)
        dsh.path = FileManager.default.fileExists(atPath: dshApp) ? dshApp : nil
        if dsh.path != nil, let feed = await Self.electronFeed(app: dshApp) {
            dsh.latest = feed.version
            dsh.upgrade = .feed(app: dshApp, file: feed.url, sha512: feed.sha512, version: feed.version)
        } else if dsh.path != nil { dsh.problem = "读取不到更新源" }
        next.append(dsh)

        for (kind, app) in [(Kind.workbuddy, "/Applications/WorkBuddy.app"), (.claudeApp, "/Applications/Claude.app")] {
            guard FileManager.default.fileExists(atPath: app) else { next.append(.init(kind: kind)); continue }
            next.append(.init(kind: kind, installed: Self.plistVersion(app), latest: nil, path: app, problem: nil, upgrade: .openApp(app)))
        }
        items = next
    }

    private func version(_ path: String) async -> (version: String?, error: String?) {
        guard let result = try? await runner.run(.init(command: path, arguments: ["--version"], directory: NSTemporaryDirectory(), timeout: 20)) else {
            return (nil, "无法运行 \(path)")
        }
        let text = result.stdout + result.stderr
        let match = text.firstMatch(of: /\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?/).map { String($0.output) }
        return (result.exitCode == 0 ? match : nil, result.exitCode == 0 ? nil : text)
    }

    private static func npmLatest(_ package: String) async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/\(package.replacingOccurrences(of: "/", with: "%2F"))/latest"),
              let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// electron-updater's generic feed: `<url>/<channel>-mac.yml` from the app's own `app-update.yml`.
    private static func electronFeed(app: String) async -> (version: String, url: URL, sha512: String)? {
        guard let config = try? String(contentsOfFile: app + "/Contents/Resources/app-update.yml", encoding: .utf8) else { return nil }
        func value(_ key: String, in text: String) -> String? {
            text.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        }
        guard var base = value("url", in: config), base.hasPrefix("https://") else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        let channel = value("channel", in: config) ?? "latest"
        guard let feedURL = URL(string: base + channel + "-mac.yml"),
              let (data, _) = try? await URLSession.shared.data(from: feedURL) else { return nil }
        let feed = String(decoding: data, as: UTF8.self)
        // `url: >-` folds onto the next line in these feeds; take the first https zip and its sha512.
        guard let version = value("version", in: feed),
              let zip = feed.firstMatch(of: /https:\/\/[^\s]+\.zip/).map({ String($0.output) }), let url = URL(string: zip),
              url.host != nil, url.host == URL(string: base)?.host,
              let sha = feed.components(separatedBy: "sha512:").dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ">-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespacesAndNewlines).first,
              !sha.isEmpty else { return nil }
        return (version, url, sha)
    }

    func upgrade(_ item: Item) async {
        guard let upgrade = item.upgrade, working == nil else { return }
        working = item.kind
        defer { working = nil }
        log[item.kind] = "开始：\(upgrade.summary)\n"
        do {
            switch upgrade {
            case .npm(let package, let npm):
                try await run(item.kind, npm, ["install", "-g", "\(package)@latest"])
            case .command(let command, let arguments):
                try await run(item.kind, command, arguments)
            case .feed(let app, let file, let sha512, let version):
                try await replaceApp(item.kind, app: app, from: file, sha512: sha512, version: version)
            case .openApp(let app):
                NSWorkspace.shared.open(URL(fileURLWithPath: app))
                log[item.kind, default: ""] += "已打开应用，请在应用菜单里检查更新。\n"
            }
            await check()
            log[item.kind, default: ""] += "完成。当前版本：\(items.first { $0.kind == item.kind }?.installed ?? "未知")\n"
        } catch {
            log[item.kind, default: ""] += "失败：\(error.localizedDescription)\n"
        }
    }

    private func run(_ kind: Kind, _ command: String, _ arguments: [String]) async throws {
        let result = try await runner.run(.init(command: command, arguments: arguments, directory: NSTemporaryDirectory(), timeout: 900, idleTimeout: 300)) { [weak self] line, _ in
            Task { @MainActor in self?.log[kind, default: ""] += line + "\n" }
        }
        guard result.exitCode == 0 else { throw RelayError.executor("命令退出码 \(result.exitCode)") }
    }

    private func replaceApp(_ kind: Kind, app: String, from url: URL, sha512: String, version: String) async throws {
        log[kind, default: ""] += "下载 \(url.absoluteString)…\n"
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError.executor("下载失败") }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard Data(SHA512.hash(data: data)).base64EncodedString() == sha512 else { throw RelayError.executor("sha512 校验不一致，已放弃安装。") }
        log[kind, default: ""] += "sha512 校验通过，解压…\n"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dravion-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let unzip = try await runner.run(.init(command: "/usr/bin/ditto", arguments: ["-x", "-k", temporary.path, work.path], directory: work.path, timeout: 600))
        guard unzip.exitCode == 0, let fresh = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw RelayError.executor("解压失败：\(unzip.stderr)")
        }
        let verify = try await runner.run(.init(command: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", fresh.path], directory: work.path, timeout: 120))
        guard verify.exitCode == 0 else { throw RelayError.executor("新版本签名校验失败：\(verify.stderr)") }
        let bundleID = Bundle(path: app)?.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        if !running.isEmpty {
            log[kind, default: ""] += "正在退出旧版本…\n"
            running.forEach { $0.terminate() }
            for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) { try await Task.sleep(for: .milliseconds(250)) }
            guard running.allSatisfy(\.isTerminated) else { throw RelayError.executor("旧版本没有退出，请先手动退出后再试。") }
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: app), resultingItemURL: &trashed)
        do { try FileManager.default.moveItem(at: fresh, to: URL(fileURLWithPath: app)) }
        catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed as URL, to: URL(fileURLWithPath: app)) }
            throw error
        }
        log[kind, default: ""] += "已替换为 \(version)；旧版本在废纸篓。\n"
        if !running.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
    }
}

/// 调度设置 → 客户端版本.
struct RelayClientUpdatesCard: View {
    @Bindable var updates: RelayClientUpdates
    @State private var confirm: RelayClientUpdates.Item?
    @State private var showLog: RelayClientUpdates.Kind?

    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("客户端版本").font(.headline)
                    Text("CLI 用 npm 升级；DeepSeek Harness 读取官方更新源并校验后替换").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.checking ? "检查中…" : "检查更新") { Task { await updates.check() } }.disabled(updates.checking)
                }
                if updates.items.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取本机版本…").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                ForEach(updates.items) { item in row(item) }
            }
        }
        .task { if updates.items.isEmpty { await updates.check() } }
        .alert("确认升级 \(confirm?.kind.rawValue ?? "")", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("取消", role: .cancel) { confirm = nil }
            Button("升级") { if let item = confirm { showLog = item.kind; Task { await updates.upgrade(item) } }; confirm = nil }
        } message: {
            Text("将执行：\(confirm?.upgrade?.summary ?? "")\n正在运行的任务若用到这个客户端，建议先暂停。")
        }
    }

    private func row(_ item: RelayClientUpdates.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(item.kind.color.opacity(0.14)).frame(width: 30, height: 30)
                    .overlay(DravionIcon(name: "cpu", size: 15).foregroundStyle(item.kind.color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.kind.rawValue).font(.system(size: 13, weight: .semibold))
                    Text(item.path ?? "未安装").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.installed ?? (item.path == nil ? "—" : "未知")).font(.system(size: 12, design: .monospaced))
                        if let latest = item.latest, item.outdated {
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(latest).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(item.kind.color)
                        }
                    }
                    status(item)
                }
                if updates.working == item.kind {
                    ProgressView().controlSize(.small).frame(width: 74)
                } else if let upgrade = item.upgrade {
                    let label: String = switch upgrade {
                    case .openApp: "打开更新"
                    default: item.path == nil ? "安装" : item.problem != nil ? "修复" : item.outdated ? "升级" : "重新安装"
                    }
                    Button(label) { confirm = item }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .tint(item.outdated || item.problem != nil ? item.kind.color : .secondary)
                        .disabled(updates.working != nil).frame(width: 74)
                } else { Spacer().frame(width: 74) }
            }
            if let problem = item.problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3) }
            if let text = updates.log[item.kind], showLog == item.kind || updates.working == item.kind {
                ScrollView { Text(text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140).padding(10).background(GhosttyPalette.background, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(GhosttyPalette.foreground)
            }
        }
        .padding(10).background(item.outdated ? item.kind.color.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func status(_ item: RelayClientUpdates.Item) -> some View {
        if item.path == nil { Text("未安装").font(.system(size: 11)).foregroundStyle(.secondary) }
        else if item.problem != nil { Text("需要修复").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange) }
        else if item.outdated { Text("有新版本").font(.system(size: 11, weight: .medium)).foregroundStyle(item.kind.color) }
        else if item.latest != nil { Text("已是最新").font(.system(size: 11)).foregroundStyle(RelayPalette.green) }
        else { Text("无公开更新源").font(.system(size: 11)).foregroundStyle(.tertiary) }
    }
}
