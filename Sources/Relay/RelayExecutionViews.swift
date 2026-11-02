import SwiftUI
import RelayCore

struct RelayQuestionCard: View {
    let model: RelayAppModel
    let run: RelayRun
    let question: RelayUserQuestion
    @State private var answer = ""
    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    DravionIcon(name: "chats-circle", size: 18)
                    Text("\(run.roles.first { $0.id == run.currentRoleID }?.name ?? "团队")需要你的回答").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    RelayBadge(text: "等你回复", color: .orange)
                }
                Text(question.question).font(.system(size: 14)).textSelection(.enabled)
                if !question.options.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack { ForEach(question.options, id: \.self) { option in Button(option) { answer = option } } }
                        VStack(alignment: .leading) { ForEach(question.options, id: \.self) { option in Button(option) { answer = option } } }
                    }.buttonStyle(.bordered)
                }
                TextField("输入回答…", text: $answer, axis: .vertical).relayField().lineLimit(2...5).accessibilityIdentifier("question-answer")
                HStack {
                    Text("等待期间不调用模型，时间预算暂停。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("回复并继续") {
                        do { try model.scheduler.answer(run.id, questionID: question.id, text: answer); answer = "" }
                        catch { model.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("answer-and-resume")
                }
            }
        }
    }
}

struct RelayExternalTurnCard: View {
    let model: RelayAppModel
    let run: RelayRun
    var body: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("原客户端的调用状态需要确认").font(.headline)
                Text("共享连接已断开，项目锁仍然保留。先在原客户端查看并停止调用，确认后才可恢复、换新或释放项目。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    if let call = run.callRecords?.last, let id = call.sessionID {
                        RelaySessionActions(model: model, provider: .codex, sessionID: id)
                    }
                    Spacer()
                    Button("已在原客户端确认停止") { model.perform { try model.scheduler.confirmExternalStopped(run.id) } }
                        .disabled(model.scheduler.activeIDs.contains(run.id))
                }
            }
        }
    }
}

struct RelayRunIdentity: View {
    let model: RelayAppModel
    let run: RelayRun
    private var call: RelayCallRecord? {
        guard let roleID = run.currentRoleID else { return nil }
        return run.callRecords?.last { $0.roleID == roleID && $0.taskID == run.currentTaskID }
    }
    var body: some View {
        RelayCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("当前调用").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let call {
                        RelayBadge(text: run.waitingForSession == nil ? call.status.label : "等待调用名额", color: call.status == .running ? RelayStyle.accent : .secondary)
                    }
                }
                Text(run.waitingForSession ?? run.tasks.first { $0.id == run.currentTaskID }?.task.title ?? run.phase.label)
                    .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let role = run.roles.first(where: { $0.id == run.currentRoleID }) {
                    let connection = run.connections.first { $0.id == role.connectionID }
                    let effective = model.effectiveModel(role, connection: connection)
                    HStack(spacing: 6) {
                        Circle().fill(RelayStyle.color(role.color)).frame(width: 6, height: 6)
                        Text(role.name).foregroundStyle(RelayStyle.color(role.color))
                        Text("· \(connection?.name ?? "连接缺失")").foregroundStyle(.secondary)
                    }.font(.system(size: 11)).lineLimit(1)
                    VStack(alignment: .leading, spacing: 4) {
                        row("配置模型", effective.model, mono: true)
                        if let call {
                            row("客户端声明", call.reportedModel ?? "未报告", mono: true)
                            row("思考级别", call.reportedEffort ?? (call.effort == "default" ? "沿用客户端配置" : call.effort + "（请求）"))
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let call, let id = call.sessionID {
                    HStack(spacing: 6) {
                        Text("会话 \(String(id.prefix(18)))…").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).help(id)
                        Spacer()
                        RelaySessionActions(model: model, provider: run.connections.first { $0.id == call.connectionID }?.kind ?? .codex, sessionID: id)
                    }
                }
            }
        }
    }
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).font(.system(size: 11, design: mono ? .monospaced : .default)).lineLimit(2).textSelection(.enabled)
        }
    }
}

struct RelayTaskList: View {
    let run: RelayRun
    let select: (String) -> Void
    var body: some View {
        if !run.tasks.isEmpty {
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("任务步骤").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("点击查看输出、代码和验收标准").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(run.tasks.enumerated()), id: \.element.id) { index, item in
                        Button { select(item.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 26).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.task.title).font(.system(size: 13, weight: .medium))
                                    Text(run.roles.first { $0.id == item.task.roleId }?.name ?? item.task.roleId).font(.system(size: 11)).foregroundStyle(.secondary)
                                    if !item.task.dependsOn.isEmpty {
                                        Text("依赖：" + item.task.dependsOn.map { id in run.tasks.first { $0.id == id }?.task.title ?? id }.joined(separator: "、"))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(item.status.label).font(.system(size: 11)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(12).contentShape(Rectangle())
                                .background(item.id == run.currentTaskID ? RelayStyle.sunken : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityIdentifier("task-detail-\(item.id)")
                    }
                    Divider().opacity(0.5)
                    HStack {
                        Text("实际测试：\(run.testExitCode.map { "退出码 \($0)" } ?? "尚未执行")")
                        Spacer()
                        Text("质检：\(reviewText(run.quality)) · 复审：\(reviewText(run.review))")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func reviewText(_ review: RelayReview?) -> String { review.map { $0.passed ? "通过" : "需返工" } ?? "尚未执行" }
}

struct RelayCallTimeline: View {
    let model: RelayAppModel
    let run: RelayRun
    var framed = true
    @State private var showAll = false
    private var calls: [RelayCallRecord] { run.callRecords ?? [] }
    var body: some View {
        if calls.isEmpty {
            if !framed {
                Text("还没有调用模型。").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            }
        } else {
            Group {
                VStack(alignment: .leading, spacing: 13) {
                    if framed {
                        HStack {
                            Text("调用记录与模型状态").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            let failures = calls.filter { $0.status == .failed }.count
                            Text("\(calls.count) 次调用 · \(failures) 次失败").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if calls.contains(where: \.modelMismatch) {
                        Text("部分调用的配置模型与客户端声明名称不同，展开可核对。名称差异可能来自别名，不能据此判断能力变化。")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    ForEach(Array((showAll || !framed ? calls : Array(calls.suffix(6))).reversed())) { call in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("指定模型：\(call.requestedModel.isEmpty ? "沿用客户端配置" : call.requestedModel)")
                                Text("客户端声明：\(call.reportedModel ?? "未报告")")
                                Text("思考级别：\(call.reportedEffort ?? (call.effort == "default" ? "未报告" : call.effort + "（请求）"))")
                                if let id = call.sessionID {
                                    HStack {
                                        Text("会话 \(id)").textSelection(.enabled)
                                        Spacer()
                                        if let connection = run.connections.first(where: { $0.id == call.connectionID }) {
                                            RelaySessionActions(model: model, provider: connection.kind, sessionID: id)
                                        }
                                    }
                                }
                                if let usage = call.usage {
                                    Text("普通输入 \(RelayTokens.text(usage.input)) · 缓存读取 \(RelayTokens.text(usage.cacheRead)) · 缓存写入 \(RelayTokens.text(usage.cacheWrite)) · 输出 \(RelayTokens.text(usage.output))")
                                } else { Text(call.status == .running ? "用量待客户端报告" : "客户端未报告本次用量").foregroundStyle(.secondary) }
                                if let error = call.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                            }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 8)
                        } label: {
                            HStack {
                                Text(call.startedAt.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                Text(run.roles.first { $0.id == call.roleID }?.name ?? call.roleID)
                                Text("· \(call.stage.label)").foregroundStyle(.secondary)
                                Spacer()
                                Text(call.resumed ? "续接" : "新会话").foregroundStyle(.secondary)
                                Text(call.status.label).frame(width: 70, alignment: .trailing)
                            }.font(.system(size: 12))
                        }
                    }
                    if framed, calls.count > 6 { Button(showAll ? "收起较早调用" : "查看全部 \(calls.count) 次调用") { showAll.toggle() }.buttonStyle(.borderless) }
                    Text("状态依据来自客户端报告、实际失败和测试结果；不会额外调用模型进行探测。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .relayFramed(framed)
        }
    }
}

struct RelayTaskDetail: View {
    let model: RelayAppModel
    let runID: String
    let taskID: String
    private var run: RelayRun? { model.store.state.runs.first { $0.id == runID } }
    var body: some View {
        if let run, let item = run.tasks.first(where: { $0.id == taskID }) {
            let role = run.roles.first { $0.id == item.task.roleId }
            VStack(spacing: 0) {
                RelayOverlayHeader(icon: "file-code", color: role.map { RelayStyle.color($0.color) } ?? .primary, title: item.task.title,
                                   subtitle: [role?.name, item.status.label, item.startedAt.flatMap { start in item.endedAt.map { "用时 " + RelayCountdown.short($0.timeIntervalSince(start)) } }]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   close: model.dismissOverlay) {
                    Button("全部子任务") { model.present("tasks", width: 720) { RelayTasksPanel(model: model, runID: runID) } }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
                Divider().opacity(0.5)
                RelayFitScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(item.task.description).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !item.task.acceptance.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("验收标准").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(item.task.acceptance, id: \.self) { line in
                                    Label { Text(line).font(.system(size: 12)) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(RelayPalette.green) }
                                }
                            }
                        }
                        if !item.task.dependsOn.isEmpty {
                            Text("依赖：" + item.task.dependsOn.map { id in run.tasks.first { $0.id == id }?.task.title ?? id }.joined(separator: "、"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if !item.output.isEmpty { RelayCodeOutput(text: item.output) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("执行记录").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            RelayTerminalLog(events: (model.store.events[runID] ?? []).filter { $0.taskID == taskID }, roles: run.roles)
                                .frame(height: 340)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
