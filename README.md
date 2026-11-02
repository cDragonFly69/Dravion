# Dravion

Dravion 是一个 macOS 原生桌面应用：把你电脑上已经在用的 AI 客户端（Claude Code、Codex、DeepSeek Harness、WorkBuddy、豆包等）组织成一支“数字员工”团队。你把工作私发给某位员工或某个群，由负责人拆解、分派、执行、复审，进度实时显示在工作台和项目会话里。

## 功能

- **数字员工与群聊**：员工长期存在，有自己的职责、模型、工作时间和候补；私聊或群里派活，员工自动拆解并分给同事。
- **工作台**：工作流画布、执行图谱与任务步骤，实时显示每位员工的状态与分支。
- **项目会话**：像 Claude / Codex 一样的对话视图，配会话分支图与执行光线动效。
- **人工确认**：需要你决定的地方直接弹出确认卡片。
- **自动化脚本**：把重复工作固定成脚本，运行时不调用模型、不花 token；员工和任务里的 Agent 都能直接调用。
- **业务模块**：小红书、Boss 直聘等业务流程，关键步骤停下等你确认，最后由你在官方平台完成发布或发送。
- **知识库**：对话、问题复盘与资料自动入库，员工随时复用。
- **额度与用量**：各账户额度、Token 消耗一目了然。

## 仓库结构

| 目录 | 内容 | 许可 |
| --- | --- | --- |
| `Sources/Relay` | 桌面应用界面与外壳（SwiftUI） | Apache-2.0 |
| `Sources/DravionKit` | 连接 Dravion 平台的客户端 | Apache-2.0 |
| `Widget/` | 桌面小组件 | Apache-2.0 |
| `Binaries/RelayCore.xcframework` | **闭源核心**：调度、派发、员工、自动化、业务流程、知识库与客户端连接器 | 见 `Binaries/LICENSE-RelayCore.md` |
| `Binaries/sidecars/` | 豆包、WorkBuddy 的 App 直连组件（二进制） | 同上 |

核心以二进制形式提供，开源部分可以完整构建并运行应用；你可以自由修改界面、增加页面，通过 `RelayCore` 的公开接口调用核心能力。

## 环境要求

- macOS 14 或更新版本，Apple Silicon（arm64）
- Xcode 26 或更新版本（需要 macOS SDK 26）
- 本机已安装并登录你要用的客户端（Claude Code、Codex 等，至少一个）
- 打包签名：钥匙串里有一个 Apple Development 证书（或用 `RELAY_SIGN_IDENTITY` 指定）
- 小组件需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`；打包时会复制 Homebrew 的 `zstd`：`brew install zstd`

## 构建与运行

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/prepare-sidecars.sh        # 下载 OpenCode 执行器（校验 sha512），只需一次
swift build --product Relay          # 编译
python3 Scripts/bundle.py --open     # 构建、签名并打开 release/Dravion.app
```

数据保存在 `~/Library/Application Support/RelayNative`；设置环境变量 `RELAY_DATA_DIR` 可改到别处（例如试用时用一个临时目录）。

## 命令行运行自动化脚本

```sh
release/Dravion.app/Contents/MacOS/Relay --run-automation <脚本 id> [--project <项目名>] [--param 键=值]
```

## 隐私

Dravion 只在本机运行：调用的是你本机已登录的客户端，密钥保存在 macOS 钥匙串，不上传你的项目或对话。App 直连组件通过 macOS 辅助功能操作你打开的应用窗口，不读取这些应用的数据文件或凭据。

## 许可

- 本仓库源码：Apache-2.0，见 `LICENSE`
- 核心二进制：见 `Binaries/LICENSE-RelayCore.md`
- 第三方组件：见 `NOTICE.md`
