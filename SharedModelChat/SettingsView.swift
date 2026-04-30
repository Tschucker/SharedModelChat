import SwiftUI
import SharedModelKit

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showFolderPicker = false
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sharedFolderSection
                    currentModelSection
                    modelSelectionSection
                    //downloadLinksSection
                    aboutSection
                }
                .padding(16)
            }
            .background(Color.Chat.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .sharedModelFolderPicker(
            isPresented: $showFolderPicker,
            backend: viewModel.bookmarkBackend
        ) { result in
            switch result {
            case .success(let url):
                viewModel.didSelectSharedFolder(url: url)
            case .failure(let error):
                viewModel.modelStatus = .error(error.localizedDescription)
            }
        }
        .alert("Delete model?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { viewModel.deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(viewModel.selectedModel.name) from the shared folder. Other apps using this model will need to re-download it.")
        }
    }
    
    // MARK: - Shared Folder
    
    private var sharedFolderSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shared model folder", systemImage: "folder")
                    .font(Font.Chat.heading)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                Text("Choose a folder accessible to other apps. Both GGUF files and MLX model directories stored here are shared across apps.")
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary)
                
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        Image(systemName: viewModel.hasSharedFolder ? "checkmark.circle.fill" : "folder.badge.plus")
                        Text(viewModel.hasSharedFolder ? "Folder connected" : "Choose folder")
                    }
                    .font(Font.Chat.heading)
                }
                .buttonStyle(MutedButtonStyle())
            }
        }
    }
    
    // MARK: - Current Model Status
    
    private var currentModelSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Current model", systemImage: "cpu")
                    .font(Font.Chat.heading)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                HStack(spacing: 8) {
                    Text(viewModel.selectedModel.name)
                        .font(Font.Chat.body)
                        .foregroundStyle(Color.Chat.textPrimary)
                    
                    Text(viewModel.selectedModel.format == .mlx ? "MLX" : "GGUF")
                        .font(Font.Chat.modelLabel)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(viewModel.selectedModel.format == .mlx
                            ? Color.Chat.success.opacity(0.15)
                            : Color.Chat.accent.opacity(0.1))
                        .foregroundStyle(viewModel.selectedModel.format == .mlx
                            ? Color.Chat.success
                            : Color.Chat.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                
                statusRow
            }
        }
    }
    
    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.modelStatus {
        case .unavailable:
            statusLabel("No shared folder configured", icon: "folder.badge.questionmark", color: Color.Chat.warning)
            
        case .notDownloaded:
            HStack {
                statusLabel("Not downloaded", icon: "arrow.down.circle", color: Color.Chat.textSecondary)
                Spacer()
                Button("Download") {
                    viewModel.downloadAndLoadModel()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            
        case .downloading(let progress, let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                statusLabel("Downloading…", icon: "arrow.down.circle", color: Color.Chat.accent)
                ProgressView(value: progress)
                    .tint(Color.Chat.accent)
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))
                    if let total {
                        Text("of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    }
                    Spacer()
                    Text("\(Int(progress * 100))%")
                }
                .font(Font.Chat.caption)
                .foregroundStyle(Color.Chat.textSecondary)
                .monospacedDigit()
            }
            
        case .ready(let url, let size):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    statusLabel("Ready", icon: "checkmark.circle.fill", color: Color.Chat.success)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(Font.Chat.modelLabel)
                            .foregroundStyle(Color.Chat.textSecondary)
                        if let size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(Font.Chat.caption)
                                .foregroundStyle(Color.Chat.textSecondary)
                        }
                        if let date = viewModel.downloadDate {
                            Text("Downloaded \(date, style: .relative) ago")
                                .font(Font.Chat.caption)
                                .foregroundStyle(Color.Chat.textSecondary)
                        }
                    }
                }
                
                Spacer()
                
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.Chat.error)
                }
            }
            
        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                statusLabel("Error", icon: "exclamationmark.triangle", color: Color.Chat.error)
                Text(msg)
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.error)
                Button("Retry") {
                    Task { await viewModel.refreshStatus() }
                }
                .buttonStyle(MutedButtonStyle())
            }
        }
    }
    
    private func statusLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(Font.Chat.caption)
            .foregroundStyle(color)
    }
    
    // MARK: - Model Selection
    
    private var modelSelectionSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("All models", systemImage: "list.bullet")
                    .font(Font.Chat.heading)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                Text("GGUF — single file, for llama.cpp engines")
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary)
                    .padding(.top, 4)
                
                ForEach(availableModels.filter { $0.format == .gguf }) { model in
                    modelRow(model)
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                Text("MLX — directory, for MLX Swift / Metal")
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary)
                
                ForEach(availableModels.filter { $0.format == .mlx }) { model in
                    modelRow(model)
                }
            }
        }
    }
    
    private func modelRow(_ model: SelectableModel) -> some View {
        let isSelected = viewModel.selectedModel.id == model.id
        
        return Button {
            viewModel.selectedModel = model
            viewModel.didChangeModel()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(Font.Chat.body)
                        .foregroundStyle(Color.Chat.textPrimary)
                    
                    HStack(spacing: 6) {
                        Text(model.format == .mlx ? "MLX" : "GGUF")
                            .font(Font.Chat.modelLabel)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(model.format == .mlx
                                ? Color.Chat.success.opacity(0.15)
                                : Color.Chat.accent.opacity(0.1))
                            .foregroundStyle(model.format == .mlx
                                ? Color.Chat.success
                                : Color.Chat.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        
                        Text(model.quantization)
                            .font(Font.Chat.modelLabel)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.Chat.accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        
                        Text(model.size)
                            .font(Font.Chat.caption)
                    }
                    .foregroundStyle(Color.Chat.textSecondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Chat.success)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.Chat.accent.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Download Links
    /*
    private var downloadLinksSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hugging Face links", systemImage: "arrow.down.circle")
                    .font(Font.Chat.heading)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                Text("Models can also be downloaded manually and placed in the shared folder.")
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary)
                
                ForEach(availableModels) { model in
                    if let url = model.huggingFaceURL {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Text(model.name)
                                    .font(Font.Chat.caption)
                                    .foregroundStyle(Color.Chat.textPrimary)
                                
                                Text(model.size)
                                    .font(Font.Chat.caption)
                                    .foregroundStyle(Color.Chat.textSecondary)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.Chat.accent)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
    */
    // MARK: - About
    
    private var aboutSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("About", systemImage: "info.circle")
                    .font(Font.Chat.heading)
                    .foregroundStyle(Color.Chat.textPrimary)
                
                Text("SharedModelKit handles model storage, discovery, and downloading for both GGUF and MLX formats. Plug in your inference engine to run actual inference.")
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.textSecondary)
                
                Link(destination: URL(string: "https://github.com/yourname/SharedModelKit")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on GitHub")
                    }
                    .font(Font.Chat.caption)
                    .foregroundStyle(Color.Chat.accent)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Settings Card

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.Chat.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.Chat.border, lineWidth: 1)
        )
    }
}
