#if canImport(WidgetKit)
import WidgetKit

enum WidgetReload {
    static func all() { WidgetCenter.shared.reloadAllTimelines() }
}
#endif
