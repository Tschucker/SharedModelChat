import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .chat
    
    enum Tab {
        case chat, settings
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.chat)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(Color.Chat.accent)
    }
}
