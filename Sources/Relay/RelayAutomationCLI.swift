import Foundation
import RelayCore

/// `Relay --run-automation <脚本 id 或名称> [--project <项目名>] [--param 键=值]…` — how any agent with a shell (task
/// executors in Claude Code, Codex, OpenCode…) runs an installed 自动化脚本 (R41): same installs, same runner, no
/// model call. Prints each step and the summary; exits 0 on success.
@MainActor enum RelayAutomationCLI {
    static func run(_ arguments: [String]) -> Never {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            print("用法：Relay --run-automation <脚本 id 或名称> [--project <项目名>] [--param 键=值]"); exit(2)
        }
        var project: String?, overrides: [String: String] = [:], index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--project" where index + 1 < arguments.count: project = arguments[index + 1]; index += 2
            case "--param" where index + 1 < arguments.count:
                let pair = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { overrides[pair[0]] = pair[1] }
                index += 2
            default: index += 1
            }
        }
        do {
            let store = try RelayStore(directory: RelayHostPaths.root, secrets: RelayKeychain())
            let host = RelayAutomationHost(store: store)
            guard let script = host.catalog.first(where: { $0.id == name || $0.name == name }) else {
                print("没有这个自动化脚本：\(name)。可用：" + host.catalog.map { "\($0.id)（\($0.name)）" }.joined(separator: "、")); exit(2)
            }
            let projectID = project.flatMap { key in store.state.projects.first { $0.name == key || $0.id == key || URL(fileURLWithPath: $0.path).lastPathComponent == key }?.id }
            Task { @MainActor in
                let run = await host.run(script.id, projectID: projectID, overrides: overrides, trigger: .employee, requestedBy: "agent")
                for (offset, step) in run.steps.enumerated() {
                    print("[\(offset + 1)] \(step.title) · " + (step.skipped ? "未运行" : "退出码 \(step.exitCode.map(String.init) ?? "-")"))
                    if !step.output.isEmpty { print(step.output) }
                }
                print(run.summary)
                exit(run.status == .succeeded ? 0 : 1)
            }
            RunLoop.main.run()
        } catch { print("打不开 Dravion 数据目录：\(error.localizedDescription)"); exit(1) }
        exit(1)
    }
}
