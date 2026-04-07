import SwiftUI
import SharedModelKit
internal import Combine

// MARK: - Selectable Model

struct SelectableModel: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let size: String
    let quantization: String
    let format: ModelFormat
    let huggingFaceURL: URL?
    
    var descriptor: ModelDescriptor? {
        ModelCatalog.find(id)
    }
    
    static func from(_ desc: ModelDescriptor, displaySize: String) -> SelectableModel {
        SelectableModel(
            id: desc.id,
            name: desc.name,
            family: desc.family,
            size: displaySize,
            quantization: desc.quantization,
            format: desc.format,
            huggingFaceURL: desc.metadata["huggingface"].flatMap(URL.init(string:))
        )
    }
}

let availableModels: [SelectableModel] = [
    // GGUF
    .from(ModelCatalog.llama3_2_1B_Q4,     displaySize: "~808 MB"),
    .from(ModelCatalog.llama3_2_3B_Q4,     displaySize: "~2.0 GB"),
    .from(ModelCatalog.gemma2_2B_Q4,       displaySize: "~1.5 GB"),
    .from(ModelCatalog.phi3_mini_Q4,       displaySize: "~2.4 GB"),
    .from(ModelCatalog.mistral7B_v03_Q4,   displaySize: "~4.4 GB"),
    // MLX
    .from(ModelCatalog.llama3_2_1B_MLX,    displaySize: "~0.7 GB"),
    .from(ModelCatalog.llama3_2_3B_MLX,    displaySize: "~1.8 GB"),
    .from(ModelCatalog.gemma3_1B_MLX,      displaySize: "~0.6 GB"),
    .from(ModelCatalog.qwen3_4B_MLX,       displaySize: "~2.5 GB"),
    .from(ModelCatalog.mistral7B_v03_MLX,  displaySize: "~4.0 GB"),
]

// MARK: - View Model

@MainActor
final class ChatViewModel: ObservableObject {
    
    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    
    // Model management (status comes from SharedModelKit)
    @Published var modelStatus: ModelStatus = .unavailable
    @Published var selectedModel: SelectableModel = availableModels[0]
    @Published var hasSharedFolder: Bool = false
    @Published var downloadDate: Date? = nil
    
    // SharedModelKit
    nonisolated(unsafe) let bookmarkBackend = BookmarkBackend()
    private nonisolated(unsafe) var store: ModelStore?
    private(set) var loadedModelURL: URL?
    
    // ╔═══════════════════════════════════════════════════════════════╗
    // ║  INFERENCE ENGINES                                           ║
    // ║                                                              ║
    // ║  The view model holds one engine per format. When the user   ║
    // ║  selects a model, `activeEngine` returns the correct one     ║
    // ║  based on the model's format from the SharedModelKit         ║
    // ║  catalog.                                                    ║
    // ║                                                              ║
    // ║  To enable real inference, uncomment the real engines below  ║
    // ║  and add their SPM dependencies to the project.              ║
    // ╚═══════════════════════════════════════════════════════════════╝
    
    // Engine for GGUF models (llama.cpp-based):
    private nonisolated(unsafe) let ggufEngine: any InferenceEngine = LlamaCppEngine()
    //private nonisolated(unsafe) let ggufEngine: any InferenceEngine = PlaceholderEngine()
    
    // Engine for MLX models (Metal-accelerated):
    private nonisolated(unsafe) let mlxEngine: any InferenceEngine = MLXSwiftEngine()
    //private nonisolated(unsafe) let mlxEngine: any InferenceEngine = PlaceholderEngine()
    
    /// Returns the correct engine for the currently selected model format.
    private var activeEngine: any InferenceEngine {
        switch selectedModel.format {
        case .mlx:
            return mlxEngine
        default:
            return ggufEngine
        }
    }
    
    init() {
        store = ModelStore(backends: [
            bookmarkBackend,
            LocalDirectoryBackend()
        ])
        
        Task {
            await store?.register(ModelCatalog.all)
            
            if await bookmarkBackend.isAvailable() {
                hasSharedFolder = true
                await refreshStatus()
            } else {
                messages = [
                    ChatMessage(
                        role: .assistant,
                        content: "Hello! Open Settings to choose a shared model folder and select a model to get started."
                    )
                ]
            }
        }
    }
    
    // MARK: - Folder Configuration
    
    func didSelectSharedFolder(url: URL) {
        do {
            try bookmarkBackend.saveBookmark(for: url)
            hasSharedFolder = true
            Task { await refreshStatus() }
        } catch {
            modelStatus = .error(error.localizedDescription)
        }
    }
    
    // MARK: - Status
    
    func refreshStatus() async {
        guard let descriptor = selectedModel.descriptor, let store else {
            modelStatus = hasSharedFolder ? .error("Unknown model") : .unavailable
            downloadDate = nil
            return
        }
        let status = await store.status(of: descriptor)
        modelStatus = status
        
        // Read download metadata for the date
        if let meta = await store.metadata(for: descriptor) {
            downloadDate = meta.downloadedAt
        } else {
            downloadDate = nil
        }
        
        if case .ready(let url, _) = status {
            if loadedModelURL != url {
                await loadIntoEngine(url: url, name: descriptor.name)
            }
        }
    }
    
    // MARK: - Download & Load
    
    /// SharedModelKit handles the entire download for both GGUF and MLX.
    func downloadAndLoadModel() {
        guard let descriptor = selectedModel.descriptor, let store else {
            modelStatus = .unavailable
            return
        }
        
        Task {
            do {
                let url = try await store.modelURL(for: descriptor) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let progress = total.map { Double(received) / Double($0) } ?? 0
                        self.modelStatus = .downloading(
                            progress: min(progress, 1.0),
                            receivedBytes: received,
                            totalBytes: total
                        )
                    }
                }
                
                await loadIntoEngine(url: url, name: descriptor.name)
            } catch {
                modelStatus = .error(error.localizedDescription)
            }
        }
    }
    
    func loadReadyModel() {
        guard case .ready(let url, _) = modelStatus,
              let name = selectedModel.descriptor?.name else { return }
        Task { await loadIntoEngine(url: url, name: name) }
    }
    
    private func loadIntoEngine(url: URL, name: String) async {
        let engine = activeEngine
        
        do {
            // Unload both engines to free memory before loading
            await ggufEngine.unloadModel()
            await mlxEngine.unloadModel()
            
            try await engine.loadModel(from: url)
            
            loadedModelURL = url
            modelStatus = .ready(url: url, sizeBytes: nil)
            
            let formatLabel = selectedModel.format == .mlx ? "MLX" : "GGUF"
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: "\(name) (\(formatLabel)) loaded via \(engine.name). Ready to chat!"
                )
            )
        } catch {
            modelStatus = .error("Engine load failed: \(error.localizedDescription)")
        }
    }
    
    func deleteModel() {
        guard let descriptor = selectedModel.descriptor, let store else { return }
        Task {
            do {
                try await store.delete(descriptor)
                loadedModelURL = nil
                await ggufEngine.unloadModel()
                await mlxEngine.unloadModel()
                await refreshStatus()
            } catch {
                modelStatus = .error(error.localizedDescription)
            }
        }
    }
    
    func didChangeModel() {
        loadedModelURL = nil
        Task {
            await ggufEngine.unloadModel()
            await mlxEngine.unloadModel()
            await refreshStatus()
        }
    }
    
    // MARK: - Chat
    
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelStatus.isReady else { return }
        
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isGenerating = true
        
        let responseId = UUID()
        messages.append(ChatMessage(id: responseId, role: .assistant, content: "", isStreaming: true))
        
        let conversationHistory = messages.filter { msg in
            msg.id != responseId && (msg.role == .user || msg.role == .assistant)
        }
        
        // Capture the active engine for this generation
        let engine = activeEngine
        
        Task {
            do {
                _ = try await engine.generate(messages: conversationHistory) { [weak self] token in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let idx = self.messages.firstIndex(where: { $0.id == responseId })
                        else { return }
                        self.messages[idx] = ChatMessage(
                            id: responseId,
                            role: .assistant,
                            content: self.messages[idx].content + token,
                            timestamp: self.messages[idx].timestamp,
                            isStreaming: true
                        )
                    }
                }
                
                if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                    messages[idx] = ChatMessage(
                        id: responseId,
                        role: .assistant,
                        content: messages[idx].content,
                        timestamp: messages[idx].timestamp,
                        isStreaming: false
                    )
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                    messages[idx] = ChatMessage(
                        id: responseId,
                        role: .assistant,
                        content: "Error: \(error.localizedDescription)",
                        timestamp: messages[idx].timestamp,
                        isStreaming: false
                    )
                }
            }
            isGenerating = false
        }
    }
    
    func clearChat() {
        messages = []
        isGenerating = false
    }
}
