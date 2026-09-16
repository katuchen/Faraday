import SwiftUI

@main
struct FaradayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.anySimulatorOffline ? "network.slash" : "network")
        }
        .menuBarExtraStyle(.window)
    }
}
