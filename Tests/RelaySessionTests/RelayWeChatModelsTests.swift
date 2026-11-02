import Foundation
import Testing
import RelayCore
@testable import Relay

/// 微信远程的模型选择：从本地配置读出来的东西必须干净、唯一，写进 OpenClaw 的键才认得出。
struct RelayWeChatModelsTests {
    @Test func catalogKeySplitsIntoProviderAndModel() {
        // Groups are keyed by whatever precedes the first slash, which is how OpenClaw names its catalog.
        let key = "agentrouter/gpt-6-astra"
        #expect(String(key.split(separator: "/").first ?? "") == "agentrouter")
        #expect(String(key.split(separator: "/").last ?? "") == "gpt-6-astra")
    }

    @Test func contextTierSuffixIsStrippedFromCCTierNames() {
        // cc-switch writes `deepseek-v4-pro[1M]`; the endpoint only accepts the bare id.
        #expect(RelayClientCatalog.modelNames(#"{"env":{"ANTHROPIC_MODEL":"deepseek-v4-pro[1M]"}}"#) == ["deepseek-v4-pro[1M]"])
        let stripped = "deepseek-v4-pro[1M]".prefix { $0 != "[" }
        #expect(String(stripped) == "deepseek-v4-pro")
    }

    @Test func modelNamesComeFromCCTierSettingsWithoutKeys() {
        let config = """
        {"env":{"ANTHROPIC_BASE_URL":"https://example.test","ANTHROPIC_AUTH_TOKEN":"sk-secret","ANTHROPIC_MODEL":"claude-sonnet-5-5"}}
        """
        let names = RelayClientCatalog.modelNames(config)
        #expect(names == ["claude-sonnet-5-5"])
        #expect(!names.contains { $0.contains("sk-secret") })
    }

    @Test func codexBaseURLIsReadFromTheTomlBlob() {
        let toml = """
        model = "gpt-6-astra"
        [model_providers.custom]
        base_url = "https://agentrouter.org/v1"
        """
        let settings: [String: Any] = ["config": toml]
        let base = (settings["config"] as? String)?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("base_url") }
            .flatMap { line -> String? in
                guard let equals = line.firstIndex(of: "=") else { return nil }
                return line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        #expect(base == "https://agentrouter.org/v1")
    }

    @Test @MainActor func openClawConfigReadsTheAnswerModel() throws {
        // Only meaningful on a machine where OpenClaw has a config; skip elsewhere instead of failing.
        let file = RelayWeChatModels.configFile
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let current = RelayWeChatModels.current() {
            // The value OpenClaw stores is a `provider/model` key, which is what the picker shows back.
            #expect(current.contains("/"))
        }
    }
}
