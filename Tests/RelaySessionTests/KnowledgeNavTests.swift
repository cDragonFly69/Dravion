import Testing
@testable import Relay

/// The outer sidebar is user-confirmed (AGENTS.md “双层导航”): the original entries keep their order, and 知识库 is
/// appended once at the end. K1 review: this was previously only checked in screenshots. 自动化 and 业务模块 sit above
/// 收件箱 (user request, 2026-11-02).
@Suite struct KnowledgeNavTests {
    @Test func knowledgeIsTheLastPrimaryEntry() {
        #expect(RelayNav.primary == [
            .page(.dashboard), .work(.channels), .work(.people), .work(.background),
            .page(.automation), .page(.business), .work(.inbox), .page(.knowledge)
        ])
        #expect(RelayNav.primary.map(\.title) == ["工作台", "群聊", "员工", "后台工作", "自动化", "业务模块", "收件箱", "知识库"])
        #expect(RelayNav.primary.last == .page(.knowledge))
        #expect(RelaySection.knowledge.icon == "books")
    }
}
