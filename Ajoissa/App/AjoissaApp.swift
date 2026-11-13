import SwiftUI

@main
struct AjoissaApp: App {
    var body: some Scene {
        MenuBarExtra("Ajoissa", systemImage: StatusMenuView.menuBarSymbolName) {
            StatusMenuView()
        }
        .menuBarExtraStyle(.window)
    }
}
