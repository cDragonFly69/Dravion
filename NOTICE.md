# 第三方声明

本仓库及其构建产物包含或使用以下第三方组件，各自遵循原许可：

| 组件 | 许可 | 用途 |
| --- | --- | --- |
| api-use（Pulse） | Apache-2.0，见 `Vendor/APIUse-LICENSE`、`Vendor/NOTICE.md` | 账户额度与用量界面（`Sources/Relay/APIUse`） |
| Lancer（豆包桥接与 Light UI 动效的移植） | MIT，见 `Vendor/Lancer-LICENSE` | `Binaries/sidecars/doubao-bridge` 与光线动效 |
| Sparkle 2.9.6 | MIT | 应用更新（SwiftPM 依赖） |
| Phosphor Icons 2.1.1 | MIT | `Sources/Relay/Icons/phosphor` |
| Element Plus Icons 2.3.1 | MIT | `Sources/Relay/Icons/element-plus` |
| OpenCode 1.19.5 | MIT | 构建时由 `Scripts/prepare-sidecars.sh` 下载的执行器，不在仓库内 |
| Zstandard | BSD-3-Clause | 打包时复制本机 Homebrew 的动态库，不在仓库内 |
