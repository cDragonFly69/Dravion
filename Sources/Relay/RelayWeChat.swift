import SwiftUI
import RelayCore

/// WeChat as a remote control, through OpenClaw's official WeChat channel (微信 ClawBot, `openclaw-weixin`).
///
/// - Out: when a run needs you (a question, a finished milestone, the budget, a failure, a sandbox refusal) or
///   ends, Dravion runs `openclaw message send --channel openclaw-weixin --target <you>`.
/// - In: your reply reaches your OpenClaw agent; the `dravion` skill installed below tells it to turn the reply
///   into a request in Dravion's local inbox (`RelayInbox`: answer / confirm / instruct / extend / resume /
///   stop / status / create), the same path as the buttons. Nothing listens on the network.
@MainActor enum RelayWeChat {
    static let channel = "openclaw-weixin"
    private static let defaults = UserDefaults.standard
    static var enabled: Bool { get { defaults.bool(forKey: "relay.wechat.enabled") } set { defaults.set(newValue, forKey: "relay.wechat.enabled") } }
    static var target: String { get { defaults.string(forKey: "relay.wechat.target") ?? "" } set { defaults.set(newValue, forKey: "relay.wechat.target") } }
    /// The last failed notification (shown in 调度设置 → 微信远程 only; user feedback 2026-11-01: never as a banner).
    static var lastFailure: String { get { defaults.string(forKey: "relay.wechat.lastFailure") ?? "" } set { defaults.set(newValue, forKey: "relay.wechat.lastFailure") } }
    static var account: String { get { defaults.string(forKey: "relay.wechat.account") ?? "" } set { defaults.set(newValue, forKey: "relay.wechat.account") } }
    static var notifyFinished: Bool { get { defaults.object(forKey: "relay.wechat.finished") as? Bool ?? true } set { defaults.set(newValue, forKey: "relay.wechat.finished") } }

    static var openclaw: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (RelayEnvironment.child()["PATH"] ?? "").split(separator: ":").map { String($0) + "/openclaw" }
        return (["/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw", "\(home)/.local/bin/openclaw"] + path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// WeChat user ids of logged-in ClawBot accounts (`~/.openclaw/openclaw-weixin/accounts/*.json`). Only the
    /// `userId` field is kept; the token in those files is never stored or shown.
    static func loggedInUsers() -> [(account: String, userId: String)] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/openclaw-weixin/accounts")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), data.count < 64_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let user = (json["userId"] as? String)?.trimmingCharacters(in: .whitespaces), !user.isEmpty else { return nil }
            return (file.deletingPathExtension().lastPathComponent, user)
        }
    }

    static func send(_ text: String) async throws {
        guard let openclaw else { throw RelayError.invalid("未找到 openclaw 命令。请先在“客户端版本”里安装 OpenClaw。") }
        guard !target.isEmpty else { throw RelayError.invalid("请先填写或读取接收消息的微信用户。") }
        var arguments = ["message", "send", "--channel", channel, "--target", target, "--message", String(text.prefix(3_800))]
        if !account.isEmpty { arguments += ["--account", account] }
        let result = try await RelayProcessRunner().run(.init(command: openclaw, arguments: arguments, directory: NSTemporaryDirectory(), timeout: 45))
        guard result.exitCode == 0 else { throw RelayError.executor("OpenClaw 发送失败（\(result.exitCode)）：\(String((result.stderr + result.stdout).prefix(400)))") }
    }

    /// Sends a run's state if WeChat is on; failures go to the notice bar, never into the run.
    static func notify(_ run: RelayRun, model: RelayAppModel) {
        guard enabled, !target.isEmpty, !model.isUITest else { return }
        let text = message(for: run, model: model)
        Task {
            do { try await send(text); lastFailure = "" }
            catch {
                let clock = Date().formatted(date: .abbreviated, time: .shortened)
                lastFailure = "\(clock) 未发出：" + String(model.store.redact(error.localizedDescription).prefix(300))
            }
        }
    }

    static func message(for run: RelayRun, model: RelayAppModel) -> String {
        let tag = "#" + run.id.prefix(6)
        var lines = ["【Dravion】\(run.input.title) \(tag)", "项目：\(run.project.name)"]
        var replies: [String] = []
        if let question = run.pendingQuestion {
            lines.append("❓ \(model.store.state.roles.first { $0.id == run.currentRoleID }?.name ?? "员工")问：\(question.question)")
            if !question.options.isEmpty { lines.append("选项：" + question.options.joined(separator: " / ")) }
            replies.append("答 <你的回答>")
        } else if run.pause?.reason == .milestone, let next = run.nextMilestone, let milestones = run.milestones {
            let done = milestones.filter { $0.status == .done }
            lines.append("✅ 第 \(done.count) 阶段「\(done.last?.title ?? "")」完成：\(done.last?.summary ?? "")")
            lines.append("➡️ 下一阶段「\(milestones[next].title)」：\(milestones[next].goal)")
            replies += ["确认", "确认 <改写后的目标>", "结束"]
        } else if run.pause?.reason == .budget {
            lines.append("⏳ 时间预算用完，已在步骤之间暂停。")
            replies += ["加时 30 / 加时 60", "不限时", "结束"]
        } else if let pause = run.pause, run.status == .paused {
            lines.append("⏸ \(pause.message.prefix(300))")
            replies += ["继续", "补充 <要求>"]
        } else if run.status == .failed {
            lines.append("❌ 失败：\((run.error ?? "").prefix(300))")
            replies += ["继续（从失败处接着做）", "补充 <要求>"]
        } else if run.status == .succeeded {
            lines.append("🎉 已完成：\(run.output.prefix(300))")
        } else {
            lines.append(run.activityLabel)
        }
        let denied = RelaySandboxHint.directories(for: run, events: model.store.events[run.id] ?? [])
        if let directory = denied.first { lines.append("🔒 需要写入：\(directory)"); replies.append("允许写入") }
        if !replies.isEmpty { lines.append("回复：" + replies.joined(separator: " ｜ ")) }
        return lines.joined(separator: "\n")
    }

    static var skillDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/skills/dravion")
    }
    static var skillInstalled: Bool { FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("SKILL.md").path) }

    /// The OpenClaw skill that turns WeChat replies into Dravion inbox requests.
    static func installSkill() throws {
        let inbox = RelayHostPaths.root.appendingPathComponent("inbox").path
        let skill = """
        ---
        name: dravion
        description: Relay the user's WeChat replies about Dravion desktop tasks (messages tagged 【Dravion】 or #xxxxxx, or replies like 答/确认/继续/加时/补充/停止/允许写入/状态/新任务) into the local Dravion app, and report the result back.
        ---

        # Dravion remote control

        Dravion is a local desktop app that runs coding tasks. It sends the user WeChat messages that start with
        `【Dravion】` and carry a task tag like `#1a2b3c`. When the user replies about a Dravion task, write ONE JSON
        request file into Dravion's inbox and read the result; do not do the coding work yourself.

        Inbox: `\(inbox)`

        1. Write the request to `\(inbox)/wechat-<unix-ms>.json` (write to a `.tmp` name first, then rename to `.json`).
        2. Wait up to 10 seconds for `\(inbox)/done/wechat-<unix-ms>.result.json` and read it.
        3. Reply to the user in Chinese with one short line: what happened (`ok` / `error`, and `summary` if present).

        `run` is the tag without `#` (a unique prefix of the task id). Leave it out when the user does not name a
        task: Dravion then picks the one task that is waiting for them.

        | User says | Request |
        | --- | --- |
        | 答 <text> | `{"action":"answer","run":"<tag>","text":"<text>"}` |
        | 确认 / 确认 <new goal> | `{"action":"confirm","run":"<tag>","text":"<new goal or omit>"}` |
        | 继续 | `{"action":"resume","run":"<tag>"}` |
        | 加时 60 / 不限时 | `{"action":"extend","run":"<tag>","minutes":60}` / `{"action":"extend","run":"<tag>","minutes":0}` |
        | 补充 <text> | `{"action":"instruct","run":"<tag>","text":"<text>"}` |
        | 允许写入 | `{"action":"grant","run":"<tag>"}` |
        | 停止 / 结束 | `{"action":"stop","run":"<tag>"}` |
        | 状态 / 进度 | `{"action":"status"}` (then send the `summary` text back) |
        | 新任务 <goal> | `{"action":"create","goal":"<goal>","project":"<project name if the user gave one>"}` |
        | 记下来 <text> / 记下来：<text> | `{"action":"remember","text":"<text>"}` (the personal knowledge base takes it verbatim; reply with `summary`) |

        Never put secrets, keys or file contents into requests. If the reply is ambiguous, ask the user one short
        question instead of guessing.
        """
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(skill.utf8).write(to: skillDirectory.appendingPathComponent("SKILL.md"), options: .atomic)
    }
}

/// 调度设置 → 微信远程.
struct RelayWeChatCard: View {
    @Bindable var model: RelayAppModel
    @State private var enabled = RelayWeChat.enabled
    @State private var target = RelayWeChat.target
    @State private var account = RelayWeChat.account
    @State private var finished = RelayWeChat.notifyFinished
    @State private var users: [(account: String, userId: String)] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(RelayPalette.green.opacity(0.14)).frame(width: 30, height: 30)
                        .overlay(DravionIcon(name: "chats-circle", size: 16).foregroundStyle(RelayPalette.green))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("微信远程（OpenClaw 微信 ClawBot）").font(.headline)
                        Text("需要你确认时发到微信；在微信里回复就能回答、确认下一阶段、加时、补充要求或停止。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                        .onChange(of: enabled) { _, value in RelayWeChat.enabled = value }
                }
                VStack(alignment: .leading, spacing: 6) {
                    step(1, RelayWeChat.openclaw != nil, "安装 OpenClaw", RelayWeChat.openclaw ?? "在上面的“客户端版本”里安装 OpenClaw")
                    step(2, !users.isEmpty, "接入微信 ClawBot", users.isEmpty ? "终端执行 npx -y @tencent-weixin/openclaw-weixin-cli install，用微信扫码（微信 → 我 → 设置 → 插件 → ClawBot）" : "已登录 \(users.count) 个微信账号")
                    step(3, RelayWeChat.skillInstalled, "安装 Dravion 技能", "让 OpenClaw 把你的微信回复转成 Dravion 指令")
                }
                HStack {
                    TextField("接收消息的微信用户 ID", text: $target).textFieldStyle(.roundedBorder)
                        .onChange(of: target) { _, value in RelayWeChat.target = value.trimmingCharacters(in: .whitespaces) }
                    if !users.isEmpty {
                        Menu("读取") {
                            ForEach(users, id: \.userId) { user in
                                Button("\(user.userId)（账号 \(user.account)）") { target = user.userId; account = user.account; RelayWeChat.account = user.account }
                            }
                        }.fixedSize()
                    }
                }
                Divider().opacity(0.5)
                RelayWeChatModelPicker { message in status = message }
                Divider().opacity(0.5)
                Toggle("任务完成时也发送", isOn: $finished).font(.system(size: 12))
                    .onChange(of: finished) { _, value in RelayWeChat.notifyFinished = value }
                HStack {
                    Button(RelayWeChat.skillInstalled ? "重新安装技能" : "安装 Dravion 技能") {
                        model.perform { try RelayWeChat.installSkill(); status = "技能已写入 \(RelayWeChat.skillDirectory.path)。重启 OpenClaw Gateway（openclaw gateway restart）后生效。" }
                    }
                    Button(busy ? "发送中…" : "发送测试消息") {
                        busy = true
                        Task {
                            do { try await RelayWeChat.send("【Dravion】微信远程已连接。之后任务需要你确认时会发到这里。"); status = "测试消息已发送，请在微信查看。" }
                            catch { status = model.store.redact(error.localizedDescription) }
                            busy = false
                        }
                    }.disabled(busy || target.isEmpty || RelayWeChat.openclaw == nil)
                    Spacer()
                    Button("刷新") { users = RelayWeChat.loggedInUsers() }.buttonStyle(.borderless)
                }
                if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if !RelayWeChat.lastFailure.isEmpty {
                    Text("最近一次通知：\(RelayWeChat.lastFailure)").font(.system(size: 11)).foregroundStyle(.orange)
                        .textSelection(.enabled).lineLimit(3)
                }
                Text("个人微信的 ClawBot 只能先由你给它发过一条消息，它才能主动给你发消息。消息通过本机 OpenClaw 发出，Dravion 不监听网络端口；回复经本地收件箱处理，和点按钮走同一套检查。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { users = RelayWeChat.loggedInUsers() }
    }

    private func step(_ number: Int, _ done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RelayStepMark(state: done ? .done : .pending, number: number, color: RelayPalette.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11, design: number == 2 && !done ? .monospaced : .default)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
