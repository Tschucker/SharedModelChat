import SwiftUI
import SharedModelKit

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            Divider()
                .foregroundStyle(Color.Chat.border)
            
            if !viewModel.modelStatus.isReady {
                modelStatusBanner
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color.Chat.canvas)
            
            inputBar
        }
        .background(Color.Chat.canvas)
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SharedModelKit")
                    .font(Font.Chat.title)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                if case .ready(let url, let size) = viewModel.modelStatus {
                    HStack(spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(Font.Chat.modelLabel)
                            .foregroundStyle(Color.Chat.success)
                        
                        if let size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(Font.Chat.modelLabel)
                                .foregroundStyle(Color.Chat.textSecondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            if !viewModel.messages.isEmpty {
                Button {
                    viewModel.clearChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.Chat.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.Chat.surface)
    }
    
    // MARK: - Model Status Banner
    
    private var modelStatusBanner: some View {
        HStack(spacing: 10) {
            Group {
                switch viewModel.modelStatus {
                case .unavailable:
                    Label("Select a shared folder in Settings", systemImage: "folder.badge.questionmark")
                    
                case .notDownloaded:
                    Label(
                        viewModel.selectedModel.format == .mlx
                            ? "MLX model not downloaded"
                            : "Model not found in shared folder",
                        systemImage: "arrow.down.circle"
                    )
                    Spacer()
                    Button("Download") {
                        viewModel.downloadAndLoadModel()
                    }
                    .buttonStyle(MutedButtonStyle())
                    
                case .downloading(let progress, let received, let total):
                    Label("Downloading…", systemImage: "arrow.down.circle")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: progress)
                            .tint(Color.Chat.accent)
                            .frame(width: 100)
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))
                            if let total {
                                Text("/ \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            }
                        }
                        .font(Font.Chat.caption)
                        .foregroundStyle(Color.Chat.textSecondary)
                        .monospacedDigit()
                    }
                    
                case .error(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.Chat.error)
                    Spacer()
                    Button("Retry") {
                        Task { await viewModel.refreshStatus() }
                    }
                    .buttonStyle(MutedButtonStyle())
                    
                case .ready:
                    EmptyView()
                }
            }
            .font(Font.Chat.caption)
            .foregroundStyle(Color.Chat.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.Chat.surface.opacity(0.7))
    }
    
    // MARK: - Input Bar
    
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
                .foregroundStyle(Color.Chat.border)
            
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $viewModel.inputText, axis: .vertical)
                    .font(Font.Chat.inputField)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.Chat.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.Chat.border, lineWidth: 1)
                    )
                    .focused($isInputFocused)
                
                Button {
                    viewModel.sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(sendButtonEnabled ? Color.Chat.textOnDark : Color.Chat.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(sendButtonEnabled ? Color.Chat.userBubble : Color.Chat.border.opacity(0.5))
                        .clipShape(Circle())
                }
                .disabled(!sendButtonEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.Chat.surface)
        }
    }
    
    private var sendButtonEnabled: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && viewModel.modelStatus.isReady
        && !viewModel.isGenerating
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    
    private var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 48) }
            
            if !isUser {
                Circle()
                    .fill(Color.Chat.accent.opacity(0.2))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "cpu")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Chat.accent)
                    )
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(Font.Chat.body)
                    .foregroundStyle(isUser ? Color.Chat.textOnDark : Color.Chat.textOnLight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.Chat.userBubble : Color.Chat.aiBubble)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if message.isStreaming {
                            streamingIndicator
                                .offset(x: -12, y: -8)
                        }
                    }
                
                Text(message.timestamp, style: .time)
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary.opacity(0.6))
            }
            
            if !isUser { Spacer(minLength: 48) }
        }
    }
    
    private var streamingIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.Chat.textSecondary.opacity(0.5))
                    .frame(width: 4, height: 4)
                    .offset(y: dotOffset(for: i))
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: message.isStreaming
                    )
            }
        }
    }
    
    private func dotOffset(for index: Int) -> CGFloat {
        message.isStreaming ? -3 : 0
    }
}
