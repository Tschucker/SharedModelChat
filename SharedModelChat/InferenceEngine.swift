import Foundation
internal import Tokenizers

// ═══════════════════════════════════════════════════════════════════
// MARK: - Inference Engine Protocol
// ═══════════════════════════════════════════════════════════════════
//
// SharedModelKit gives you a file URL. This protocol defines the
// interface between that URL and actual token generation. Pick the
// engine that suits your project and uncomment its implementation.

/// A common interface for on-device LLM inference engines.
///
/// Adopters load a GGUF (or MLX) model from a file URL and stream
/// generated tokens back to the caller.
protocol InferenceEngine: Sendable {
    
    /// Human-readable engine name (for UI display).
    var name: String { get }
    
    /// Load a model from a file URL.
    func loadModel(from url: URL) async throws
    
    /// Generate a response for the given messages.
    /// Calls `onToken` for each generated token (for streaming UI).
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
    
    /// Release model resources.
    func unloadModel() async
}


// ═══════════════════════════════════════════════════════════════════
// MARK: - 1. llama.cpp via llama.swift (mattt)
// ═══════════════════════════════════════════════════════════════════
//
// The thinnest wrapper — re-exports the llama.cpp C API directly.
// You write the sampling loop yourself, giving full control.
//
// SPM: .package(url: "https://github.com/mattt/llama.swift", from: "2.8628.0")
//
// Best for: developers who want direct llama.cpp access and are
// comfortable with the C API.
//
// ┌─────────────────────────────────────────────────────────────────┐

/*
import llama

final class LlamaCppEngine: InferenceEngine, @unchecked Sendable {
    let name = "llama.cpp"
    
    private var model: OpaquePointer?   // llama_model *
    private var context: OpaquePointer? // llama_context *
    private let contextSize: Int32 = 4096
    
    func loadModel(from url: URL) async throws {
        // Initialize the llama.cpp backend (call once per app lifecycle)
        llama_backend_init()
        
        // Load model
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99  // offload all layers to Metal
        
        model = llama_model_load_from_file(url.path, modelParams)
        guard model != nil else {
            throw InferenceError.modelLoadFailed(url.lastPathComponent)
        }
        
        // Create context
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_threads = UInt32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        ctxParams.n_threads_batch = ctxParams.n_threads
        
        context = llama_init_from_model(model, ctxParams)
        guard context != nil else {
            throw InferenceError.contextCreationFailed
        }
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let model, let context else {
            throw InferenceError.modelNotLoaded
        }
        
        // Format messages into a prompt string using the model's chat template
        let prompt = formatPrompt(messages)
        
        // Tokenize
        let promptTokens = tokenize(prompt, addBos: true)
        
        // Clear KV cache for a fresh generation
        llama_kv_cache_clear(context)
        
        // Create a batch and evaluate the prompt
        var batch = llama_batch_init(Int32(promptTokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        
        for (i, token) in promptTokens.enumerated() {
            llama_batch_add(&batch, token, Int32(i), [0], i == promptTokens.count - 1)
        }
        
        guard llama_decode(context, batch) == 0 else {
            throw InferenceError.decodeFailed
        }
        
        // Sample tokens one at a time
        var result = ""
        let maxTokens = 512
        var nCur = Int32(promptTokens.count)
        
        for _ in 0..<maxTokens {
            // Greedy sampling from logits
            let logits = llama_get_logits_ith(context, batch.n_tokens - 1)!
            let nVocab = llama_vocab_n_tokens(llama_model_get_vocab(model))
            
            var candidates: [llama_token_data] = (0..<nVocab).map {
                llama_token_data(id: $0, logit: logits[Int($0)], p: 0)
            }
            var candidatesP = llama_token_data_array(
                data: &candidates, size: candidates.count, sorted: false, selected: 0
            )
            
            let newToken = llama_sampler_sample(nil, context, -1)
            
            // Check for end of generation
            if llama_vocab_is_eog(llama_model_get_vocab(model), newToken) { break }
            
            // Convert token to string
            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(llama_model_get_vocab(model), newToken, &buf, 256, 0, true)
            if len > 0 {
                let piece = String(cString: buf)
                result += piece
                onToken(piece)
            }
            
            // Prepare next batch
            batch.n_tokens = 0
            llama_batch_add(&batch, newToken, nCur, [0], true)
            nCur += 1
            
            guard llama_decode(context, batch) == 0 else { break }
        }
        
        return result
    }
    
    func unloadModel() async {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        self.context = nil
        self.model = nil
        llama_backend_free()
    }
    
    // MARK: - Helpers
    
    private func tokenize(_ text: String, addBos: Bool) -> [llama_token] {
        guard let model else { return [] }
        let maxTokens = Int32(text.utf8.count) + (addBos ? 1 : 0)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let n = llama_tokenize(
            llama_model_get_vocab(model),
            text, Int32(text.utf8.count),
            &tokens, maxTokens,
            addBos, true
        )
        return Array(tokens.prefix(Int(n)))
    }
    
    private func formatPrompt(_ messages: [ChatMessage]) -> String {
        // Basic ChatML format — works with most instruct models.
        // For production, use llama_chat_apply_template() instead.
        var prompt = ""
        for msg in messages {
            let role = msg.role == .user ? "user" : "assistant"
            prompt += "<|im_start|>\(role)\n\(msg.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}
*/

// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - 2. LocalLLMClient (tattn)
// ═══════════════════════════════════════════════════════════════════
//
// A modern, modular Swift package supporting both llama.cpp and MLX
// backends behind a unified API. Handles chat templates automatically.
//
// SPM: .package(url: "https://github.com/tattn/LocalLLMClient", from: "0.1.0")
// Import: LocalLLMClient, LocalLLMClientLlama
//
// Best for: most developers — clean API, auto chat templates,
// supports both GGUF and MLX models.
//
// ┌─────────────────────────────────────────────────────────────────┐

/*
import LocalLLMClient
import LocalLLMClientLlama

final class LocalLLMClientEngine: InferenceEngine, @unchecked Sendable {
    let name = "LocalLLMClient"
    
    private var client: LocalLLMClient?
    
    func loadModel(from url: URL) async throws {
        client = try await LocalLLMClient.llama(
            url: url,
            parameter: .init(
                context: 4096,
                temperature: 0.7,
                topK: 40,
                topP: 0.9
            )
        )
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let client else {
            throw InferenceError.modelNotLoaded
        }
        
        // Build the conversation using LocalLLMClient's message types
        let llmMessages: [LocalLLMClient.Message] = messages.map { msg in
            switch msg.role {
            case .user:     return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            case .system:   return .system(msg.content)
            }
        }
        
        // Stream tokens
        var result = ""
        let stream = try await client.stream(llmMessages)
        
        for try await token in stream {
            result += token
            onToken(token)
        }
        
        return result
    }
    
    func unloadModel() async {
        client = nil
    }
}
*/

// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - 3. Kuzco
// ═══════════════════════════════════════════════════════════════════
//
// A Swift wrapper around llama.cpp with a high-level API focused on
// conversation and model profiles. Ships on the App Store as Haplo AI.
//
// SPM: .package(url: "https://github.com/jcjust/Kuzco", from: "1.0.0")
//
// Best for: developers who want a batteries-included conversational
// API without touching the C layer.
//
// ┌─────────────────────────────────────────────────────────────────┐

/*
import Kuzco

final class KuzcoEngine: InferenceEngine, @unchecked Sendable {
    let name = "Kuzco"
    
    private var kuzco: Kuzco?
    private var profile: ModelProfile?
    
    func loadModel(from url: URL) async throws {
        kuzco = Kuzco()
        
        // Create a model profile pointing at the GGUF file.
        // Set the architecture to match your model family.
        profile = ModelProfile(
            sourcePath: url.path,
            architecture: .llama3  // .mistral, .gemma, .phi3, etc.
        )
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let kuzco, let profile else {
            throw InferenceError.modelNotLoaded
        }
        
        // Convert messages to Kuzco's Turn format
        let dialogue: [Turn] = messages.compactMap { msg in
            switch msg.role {
            case .user:      return Turn(role: .user, text: msg.content)
            case .assistant: return Turn(role: .assistant, text: msg.content)
            case .system:    return Turn(role: .system, text: msg.content)
            }
        }
        
        // Stream tokens using Kuzco's predict API
        var result = ""
        let stream = try await kuzco.predict(
            dialogue: dialogue,
            with: profile,
            instanceSettings: .performanceFocused,
            predictionConfig: .balanced
        )
        
        for try await token in stream {
            result += token
            onToken(token)
        }
        
        return result
    }
    
    func unloadModel() async {
        kuzco = nil
        profile = nil
    }
}
*/

// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - 4. MLX Swift (Apple)
// ═══════════════════════════════════════════════════════════════════
//
// Apple's ML framework for Apple Silicon. Uses MLX-format models
// (.safetensors + config.json + tokenizer.json in a directory),
// NOT single GGUF files. For GGUF, use a llama.cpp-based engine.
//
// The libraries live in a dedicated repo:
//
// SPM (use the latest released tag — currently 2.30.x):
//   .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.30.1"))
//
// Products to link in your target:
//   .product(name: "MLXLLM", package: "mlx-swift-lm")
//   .product(name: "MLXLMCommon", package: "mlx-swift-lm")
//
// Model sources: use repos from the "mlx-community" org on HuggingFace,
//   e.g. mlx-community/Llama-3.2-3B-Instruct-4bit
//   These contain config.json, tokenizer.json, and .safetensors files
//   in a single directory.
//
// Best for: developers targeting Apple Silicon who want the fastest
// Metal-native inference.
//
// ┌─────────────────────────────────────────────────────────────────┐


import MLX
import MLXLLM
import MLXLMCommon

final class MLXSwiftEngine: InferenceEngine, @unchecked Sendable {
    let name = "MLX Swift"
    
    private var modelContainer: ModelContainer?
    
    func loadModel(from url: URL) async throws {
        // MLX expects a DIRECTORY containing config.json, tokenizer.json,
        // and .safetensors weight files — not a single GGUF file.
        //
        // For GGUF models, use one of the llama.cpp-based engines instead.
        // For MLX models, download from HuggingFace repos under "mlx-community":
        //   e.g. mlx-community/Llama-3.2-3B-Instruct-4bit
        
        // Set a Metal memory cache limit to avoid OOM on iOS
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        
        // --- Option A: Load from a local model directory ---
        // SharedModelKit gives you a directory URL for MLX-format models.
        modelContainer = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: url)
        )
        
        // --- Option B: Load by HuggingFace model ID (downloads if needed) ---
        // This bypasses SharedModelKit and downloads directly via HF Hub.
        //
        // modelContainer = try await LLMModelFactory.shared.loadContainer(
        //     configuration: ModelConfiguration(id: "mlx-community/Llama-3.2-3B-Instruct-4bit")
        // ) { progress in
        //     print("Downloading: \(Int(progress.fractionCompleted * 100))%")
        // }
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let modelContainer else {
            throw InferenceError.modelNotLoaded
        }
        
        // Build the prompt using ChatML format.
        // Most MLX-community instruct models use this template.
        let prompt = messages.map { msg in
            let role = msg.role == .user ? "user" : "assistant"
            return "<|im_start|>\(role)\n\(msg.content)<|im_end|>"
        }.joined(separator: "\n") + "\n<|im_start|>assistant\n"
        
        let generateParameters = GenerateParameters(temperature: 0.7, topP: 0.9)
        
        var result = ""
        
        try await modelContainer.perform { context in
            // Prepare the input through the model's processor
            let input = try await context.processor.prepare(
                input: .init(prompt: .text(prompt))
            )
            
            // Generate tokens with streaming callback
            try MLXLMCommon.generate(
                input: input,
                parameters: generateParameters,
                context: context
            ) { tokens in
                // decode() returns the full decoded string so far
                let fullText = context.tokenizer.decode(tokens: tokens)
                
                // Extract only the newly generated portion
                if fullText.count > result.count {
                    let newText = String(fullText.dropFirst(result.count))
                    result = fullText
                    onToken(newText)
                }
                
                return tokens.count >= 512 ? .stop : .more
            }
        }
        
        return result
    }
    
    func unloadModel() async {
        modelContainer = nil
    }
}


// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - 5. SpeziLLM (Stanford)
// ═══════════════════════════════════════════════════════════════════
//
// Stanford's open-source LLM framework for healthcare / research apps.
// Wraps llama.cpp in a SwiftUI-friendly, observation-based architecture.
//
// SPM: .package(url: "https://github.com/StanfordSpezi/SpeziLLM", from: "0.8.0")
// Import: SpeziLLMLocal
//
// Best for: research apps, healthcare, or projects that want a
// SwiftUI @Observable integration pattern.
//
// ┌─────────────────────────────────────────────────────────────────┐

/*
import SpeziLLMLocal

final class SpeziLLMEngine: InferenceEngine, @unchecked Sendable {
    let name = "SpeziLLM"
    
    private var llm: LLMLocal?
    
    func loadModel(from url: URL) async throws {
        let schema = LLMLocalSchema(
            model: .init(url: url),
            parameters: .init(
                maxOutputLength: 512,
                contextWindowSize: 4096
            ),
            samplingParameters: .init(temperature: 0.7)
        )
        
        llm = LLMLocal(schema: schema)
        try await llm?.setup()
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let llm else {
            throw InferenceError.modelNotLoaded
        }
        
        // Inject conversation context
        for msg in messages {
            switch msg.role {
            case .user:      llm.inject(prompt: msg.content, role: .user)
            case .assistant: llm.inject(prompt: msg.content, role: .assistant)
            case .system:    llm.inject(systemPrompt: msg.content)
            }
        }
        
        var result = ""
        let stream = try await llm.generate()
        
        for try await token in stream {
            result += token
            onToken(token)
        }
        
        return result
    }
    
    func unloadModel() async {
        llm = nil
    }
}
*/

// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - Placeholder Engine (for demo without inference dependency)
// ═══════════════════════════════════════════════════════════════════

/// A mock engine that simulates streaming responses.
/// Replace this with one of the real engines above.
final class PlaceholderEngine: InferenceEngine, @unchecked Sendable {
    let name = "Placeholder"
    
    private var modelPath: String = ""
    
    func loadModel(from url: URL) async throws {
        modelPath = url.lastPathComponent
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let responses = [
            "This is a placeholder response. Uncomment one of the real inference engines in InferenceEngine.swift and add its SPM dependency to use actual on-device inference with \(modelPath).",
            "The model at \(modelPath) was resolved by SharedModelKit. To generate real responses, enable an engine like LocalLLMClient, Kuzco, or raw llama.cpp — each one is ready to uncomment.",
            "Running on-device with \(modelPath). Replace PlaceholderEngine with a real engine to see actual LLM output. The integration code is already written — just uncomment it.",
            "SharedModelKit found \(modelPath) in the shared folder. Five inference engines are available in InferenceEngine.swift — pick the one that fits your project and uncomment it.",
        ]
        let response = responses[abs(messages.last?.content.hashValue ?? 0) % responses.count]
        
        for word in response.split(separator: " ") {
            try await Task.sleep(for: .milliseconds(40))
            onToken(String(word) + " ")
        }
        
        return response
    }
    
    func unloadModel() async {
        modelPath = ""
    }
}


// ═══════════════════════════════════════════════════════════════════
// MARK: - Inference Errors
// ═══════════════════════════════════════════════════════════════════

enum InferenceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case contextCreationFailed
    case decodeFailed
    case generationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded. Call loadModel(from:) first."
        case .modelLoadFailed(let name):
            return "Failed to load model: \(name)"
        case .contextCreationFailed:
            return "Failed to create inference context."
        case .decodeFailed:
            return "Token decoding failed."
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        }
    }
}
