# Relay 的第三方组件

- API Use / Pulse，© 2026 qunqin24，Apache-2.0。原生源码及小组件来自本机 api-use；来源校验和见同目录 `api-use-source-manifest.json`。Relay 修改宿主生命周期、应用名称、缓存目录、模块引用、URL scheme 和签名标识；保留原许可证与版权标注。Dravion 另给 `Settings/TokenSpendView.swift` 加了可选的 `openSession` 宿主回调（不传时与上游一致），用于在用量页点开会话。
- API Use 的 shell、tmux、SketchyBar 和 Raycast 集成也随应用提供，来源校验和见 `api-use-integrations-manifest.json`；Relay 调整默认应用路径与导航链接。
- Sparkle.framework，随原框架保留其版权、许可及各组件声明。Relay 未设置上游更新源。
- OpenCode sidecar 及其依赖的许可证收录于应用 `Contents/Resources/Licenses/sidecars`。
- Zstandard 1.5.7，© Meta Platforms, Inc. and affiliates，BSD-3-Clause。构建时从本机 Homebrew 复制动态库，随应用使用同一证书签名；许可证在 `Contents/Resources/Licenses/Zstandard-LICENSE`。Dravion 对 `DSHZstdDecoder.swift` 的宿主适配改为读取该库，并显示明确的解码错误；保留 macOS 的库签名校验。

本地构建使用 Apple Development 签名，仅用于本机验收与使用；未进行 Developer ID 公证、上传或公开发布。
