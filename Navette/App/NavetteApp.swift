import SwiftUI

@main
struct NavetteApp: App {
    @State private var model = AppModel(env: .current())

    var body: some Scene {
        Window(Text(verbatim: "Navette"), id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)
        .commands { NavetteCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}
