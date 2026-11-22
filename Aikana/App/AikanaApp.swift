import SwiftUI

@main
struct AikanaApp: App {
    @State private var model: WatchModel
    @State private var updater: Updater?

    init() {
        let model = WatchModel.live()
        if !WatchModel.isHostingTests {
            model.start(wakes: WatchModel.systemWakes())
        }
        _model = State(initialValue: model)
        _updater = State(initialValue: Updater.forThisBuild(hostingTests: WatchModel.isHostingTests))
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model, updater: updater)
        } label: {
            Image(model.menuBarImageName)
                .accessibilityLabel("Aikana: \(model.headline)")
        }
        .menuBarExtraStyle(.window)
    }
}
