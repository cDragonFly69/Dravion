import Foundation

public struct RelayTaskSnapshot: Codable, Sendable {
    public var version = 1
    public var generatedAt: Date
    public var working: Int
    public var waiting: Int
    public var completed: Int
    public var tasks: [Item]
    public init(generatedAt: Date, working: Int, waiting: Int, completed: Int, tasks: [Item]) {
        self.generatedAt = generatedAt; self.working = working; self.waiting = waiting; self.completed = completed; self.tasks = tasks
    }
    public struct Item: Codable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var state: String
        public var stateLabel: String
        public var finished: Int
        public var total: Int
        public init(id: String, title: String, state: String, stateLabel: String, finished: Int, total: Int) {
            self.id = id; self.title = title; self.state = state; self.stateLabel = stateLabel; self.finished = finished; self.total = total
        }
    }
}
