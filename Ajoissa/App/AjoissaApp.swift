import SwiftUI

@main
struct AjoissaApp: App {
    @State private var model: WatchModel

    init() {
        let model = WatchModel.live()
        if !WatchModel.isHostingTests {
            model.start(wakes: WatchModel.systemWakes())
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbolName)
                .accessibilityLabel("Ajoissa: \(model.headline)")
        }
        .menuBarExtraStyle(.window)
    }
}
