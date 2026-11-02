import SwiftUI
import RelayCore

/// "The executor could not write here" with the fix next to it: allow the directory (this run, or remembered
/// for the project) and continue, which answers the waiting question or resumes the run.
struct RelaySandboxCard: View {
    let model: RelayAppModel
    let run: RelayRun
    let directories: [String]
    @State private var remember = true

    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("员工没有写入权限").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    RelayBadge(text: "需要你授权", color: .orange)
                }
                Text("执行员工只能修改项目目录 \(run.project.path)。它要改的下面这些目录在项目外，被客户端的沙箱拒绝了。允许后，新的调用会带上这些目录的写权限并接着做。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(directories, id: \.self) { directory in
                    HStack(spacing: 10) {
                        DravionIcon(name: "folder-open", size: 16).foregroundStyle(.orange)
                        Text(directory).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                        Button("允许写入并继续") { model.perform { try model.scheduler.grantWritable(run.id, path: directory, remember: remember) } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .accessibilityIdentifier("grant-writable")
                    }
                    .padding(10).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }
                Toggle("记到项目设置，以后的任务也能写这些目录", isOn: $remember).font(.system(size: 12))
                Text("只支持 Claude Code 和 Codex；DeepSeek Harness 的沙箱只认任务目录，请改用把项目目录设成该 worktree。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35)))
    }
}
