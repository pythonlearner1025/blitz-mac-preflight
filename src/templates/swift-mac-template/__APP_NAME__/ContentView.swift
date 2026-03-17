import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macbook")
                .imageScale(.large)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Hello, macOS!")
                .font(.title)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}

#Preview {
    ContentView()
}
