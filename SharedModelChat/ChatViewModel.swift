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
    
    // Model management
    @Published var modelStatus: ModelStatus = .unavailable
    @Published var selectedModel: SelectableModel = availableModels[0]
    @Published var hasSharedFolder: Bool = false
    
    // SharedModelKit
    nonisolated(unsafe) let bookmarkBackend = BookmarkBackend()
    private nonisolated(unsafe) var store: ModelStore?
    private(set) var loadedModelURL: URL?
    
    // ╔═══════════════════════════════════════════════════════════════╗
    // ║  INFERENCE ENGINE — swap this line to change engines         ║
    // ╚═══════════════════════════════════════════════════════════════╝
    //
    //   private nonisolated(unsafe) let engine: any InferenceEngine = LlamaCppEngine()
    //   private nonisolated(unsafe) let engine: any InferenceEngine = LocalLLMClientEngine()
    //   private nonisolated(unsafe) let engine: any InferenceEngine = KuzcoEngine()
    private nonisolated(unsafe) let engine: any InferenceEngine = MLXSwiftEngine()
    //   private nonisolated(unsafe) let engine: any InferenceEngine = SpeziLLMEngine()
    //
    //private nonisolated(unsafe) let engine: any InferenceEngine = PlaceholderEngine()
    
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
    
    /// Query SharedModelKit for the current status of the selected model.
    func refreshStatus() async {
        guard let descriptor = selectedModel.descriptor else {
            modelStatus = .error("Unknown model: \(selectedModel.id)")
            return
        }
        
        guard let store else {
            modelStatus = .unavailable
            return
        }
        
        let status = await store.status(of: descriptor)
        modelStatus = status
        
        // If the model is ready, update the loaded URL
        if case .ready(let url, _) = status {
            loadedModelURL = url
        }
    }
    
    // MARK: - Download & Load
    
    /// Download the selected model via SharedModelKit, then load it into the engine.
    /// SharedModelKit handles both GGUF (single file) and MLX (HuggingFace repo directory).
    func downloadAndLoadModel() {
        guard let descriptor = selectedModel.descriptor else {
            modelStatus = .error("Unknown model: \(selectedModel.id)")
            return
        }
        
        guard let store else {
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
    
    /// Load an already-downloaded model into the inference engine.
    func loadReadyModel() {
        guard case .ready(let url, _) = modelStatus else { return }
        guard let name = selectedModel.descriptor?.name else { return }
        Task { await loadIntoEngine(url: url, name: name) }
    }
    
    private func loadIntoEngine(url: URL, name: String) async {
        do {
            await engine.unloadModel()
            try await engine.loadModel(from: url)
            
            loadedModelURL = url
            modelStatus = .ready(url: url, sizeBytes: nil)
            
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: "\(name) loaded via \(engine.name). Ready to chat!"
                )
            )
        } catch {
            modelStatus = .error("Engine load failed: \(error.localizedDescription)")
        }
    }
    
    /// Delete the selected model from all backends.
    func deleteModel() {
        guard let descriptor = selectedModel.descriptor, let store else { return }
        Task {
            do {
                try await store.delete(descriptor)
                loadedModelURL = nil
                await engine.unloadModel()
                await refreshStatus()
            } catch {
                modelStatus = .error(error.localizedDescription)
            }
        }
    }
    
    func didChangeModel() {
        loadedModelURL = nil
        Task {
            await engine.unloadModel()
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
