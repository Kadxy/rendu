import SwiftUI

struct RootView: View {
    let services: AppServices

    // Launch argument so screenshot tooling can open a specific tab.
    // No effect outside dev launches.
    @State private var tab = Self.initialTab
    @State private var browseSearch = 0

    private static var initialTab: Int {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-rendu-open-browse") || arguments.contains("-rendu-search")
            || arguments.contains("-rendu-open-sleep")
        {
            return 1
        }
        if arguments.contains("-rendu-open-settings") || arguments.contains("-rendu-open-server") { return 2 }
        return 0
    }

    var body: some View {
        if services.status.healthUnavailable {
            ContentUnavailableView(
                "Apple Health Unavailable",
                systemImage: "heart.slash",
                description: Text("This device doesn't support Apple Health.")
            )
        } else {
            tabs
                .task {
                    if ProcessInfo.processInfo.arguments.contains("-rendu-search") {
                        try? await Task.sleep(for: .seconds(1))
                        browseSearch += 1
                    }
                }
        }
    }

    private var tabs: some View {
        Group {
            TabView(selection: $tab) {
                Tab("Summary", systemImage: "heart.fill", value: 0) {
                    SummaryView(services: services)
                }
                Tab("Browse", systemImage: "square.grid.2x2.fill", value: 1) {
                    BrowseView(services: services, searchRequest: browseSearch)
                }
                Tab("Settings", systemImage: "gearshape.fill", value: 2) {
                    SettingsView(services: services)
                }
            }
        }
    }
}
