import TaskFerryCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dry-run"), i + 1 < args.count {
            let out = args[i + 1]
            Task {
                await DryRun.run(outputPath: out)
                exit(0)
            }
            dispatchMain()
        } else {
            MigratorApp.main()
        }
    }
}

struct MigratorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TaskFerry", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 920, height: 700)
    }
}
