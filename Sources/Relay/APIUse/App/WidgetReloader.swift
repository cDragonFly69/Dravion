import WidgetKit

/// Asks WidgetKit to redraw Pulse's desktop widget from the snapshot just
/// written. A request, not a guarantee: WidgetKit budgets how often it obliges.
enum WidgetReloader {
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
