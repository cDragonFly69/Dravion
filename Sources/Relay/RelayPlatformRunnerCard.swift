import SwiftUI
import AppKit
import RelayCore
import DravionKit

/// Settings card for the desktop runner (D6): the Dravion platform may run tasks on this Mac with its local
/// Codex / DeepSeek Harness. Sign in once to register the Mac; after that only the device credential is used.
struct RelayPlatformRunnerCard: View {
    @Bindable var model: RelayAppModel
    @State private var username = ""
    @State private var password = ""
    @State private var captchaCode = ""
    @State private var captcha: DravionClient.Captcha?
    @State private var busy = false
    @State private var error: String?
    private var runner: DravionRunner { model.runner }

    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("平台联调：在本机执行平台任务").font(.headline)
                        Text("开启后，Dravion 平台可以把开发任务派到这台 Mac，用本机的 Codex、DeepSeek Harness 执行。连接都由本机主动发起；平台取消任务时本机立即停下。Claude 不参与派发任务。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if runner.registered {
                        Toggle("", isOn: Binding(get: { runner.enabled }, set: { $0 ? runner.start() : runner.stop() }))
                            .toggleStyle(.switch).labelsHidden().accessibilityLabel("允许平台在本机执行任务")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("平台 API").foregroundStyle(.secondary); TextField("http://127.0.0.1:3300", text: field(\.apiURL)).textFieldStyle(.roundedBorder) }
                    GridRow { Text("管理平台").foregroundStyle(.secondary); TextField("http://127.0.0.1:8090", text: field(\.adminURL)).textFieldStyle(.roundedBorder) }
                    GridRow { Text("本机名称").foregroundStyle(.secondary); TextField("我的 Mac", text: field(\.deviceName)).textFieldStyle(.roundedBorder) }
                    GridRow {
                        Text("允许的目录").foregroundStyle(.secondary)
                        HStack {
                            Menu(runner.directory.isEmpty ? "选择项目…" : URL(fileURLWithPath: runner.directory).lastPathComponent) {
                                ForEach(model.store.state.projects) { project in Button(project.name) { model.runner.directory = project.path } }
                                Divider()
                                Button("选择其他文件夹…") { pickDirectory() }
                            }.fixedSize()
                            Text(runner.directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }.font(.system(size: 12))
                Divider()
                if runner.registered { status } else { signIn }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用平台账号登录一次，把这台 Mac 注册为设备（登录令牌只用这一次，不保存）。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("账号", text: $username).textFieldStyle(.roundedBorder).frame(width: 150)
                SecureField("密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("验证码", text: $captchaCode).textFieldStyle(.roundedBorder).frame(width: 90)
                Button { Task { await loadCaptcha() } } label: {
                    if let captcha, let image = NSImage(data: captcha.image) { Image(nsImage: image).resizable().interpolation(.none).frame(width: 100, height: 32) }
                    else { Text("获取验证码") }
                }.buttonStyle(.plain).help("点击刷新验证码")
            }
            Button(busy ? "注册中…" : "登录并注册本机") { Task { await register() } }
                .buttonStyle(.borderedProminent).disabled(busy || username.isEmpty || password.isEmpty || captchaCode.isEmpty || captcha == nil)
        }
        .task { if captcha == nil { await loadCaptcha() } }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(runner.active != nil ? RelayStyle.accent : runner.enabled ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(runner.status).font(.system(size: 12, weight: .medium))
                Spacer()
                if let id = runner.deviceID { Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled) }
                Button("移除本机凭据", role: .destructive) { runner.forget() }.font(.system(size: 11))
            }
            if let active = runner.active {
                Text("正在执行平台任务 \(active.taskID) · \(active.vendor) · 已用 \(Int(Date().timeIntervalSince(active.startedAt) / 60)) 分钟")
                    .font(.system(size: 12)).foregroundStyle(RelayStyle.accent)
            }
            Text("可派发的客户端：" + (runner.capabilities().clients.map(\.vendor).joined(separator: "、").nilIfEmpty ?? "无（需要先在“连接器”里配置 Codex 或 DeepSeek Harness）"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !runner.log.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(runner.log.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func field(_ key: ReferenceWritableKeyPath<DravionRunner, String>) -> Binding<String> {
        Binding(get: { runner[keyPath: key] }, set: { runner[keyPath: key] = $0 })
    }
    private func loadCaptcha() async {
        do { captcha = try await runner.captcha(); error = nil } catch { self.error = "获取验证码失败：\(error.localizedDescription)" }
    }
    private func register() async {
        guard let captcha else { return }
        busy = true; defer { busy = false }
        do {
            try await runner.register(username: username, password: password, captcha: captchaCode, captchaUUID: captcha.uuid)
            password = ""; captchaCode = ""; error = nil
            model.notice = "本机已注册为平台设备，打开右上角开关即可接收任务。"
        } catch {
            self.error = error.localizedDescription
            captchaCode = ""; await loadCaptcha()
        }
    }
    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.runner.directory = url.path }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
