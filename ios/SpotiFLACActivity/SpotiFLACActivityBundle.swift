import SwiftUI
import WidgetKit

/// Entry point of the Live Activity widget extension (Milestone 2).
///
/// The bundle is empty on iOS < 16.1: `ActivityConfiguration` does not exist
/// there, so registering the widget would fail to compile. Shipping an empty
/// bundle keeps the extension valid on older systems while the app simply
/// reports Live Activities as unsupported.
@main
struct SpotiFLACActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            SpotiFLACActivityWidget()
        }
    }
}
