import SwiftUI

/// Placeholder root view so the app compiles standalone before feature screens
/// land. Shows the app name and the configured API base URL (handy to confirm
/// the xcconfig → Info.plist plumbing is wired correctly on device).
struct ContentView: View {
    let apiBaseURLString: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Pose Deck")
                .font(.largeTitle.weight(.bold))
            Text("API: \(apiBaseURLString)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .padding()
    }
}

#Preview {
    ContentView(apiBaseURLString: "http://localhost:8090")
}
