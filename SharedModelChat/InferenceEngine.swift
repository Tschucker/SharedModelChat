import Foundation
internal import Tokenizers

// ═══════════════════════════════════════════════════════════════════
// MARK: - Inference Engine Protocol
// ═══════════════════════════════════════════════════════════════════

/// A common interface for on-device LLM inference engines.
protocol InferenceEngine: Sendable {
    var name: String { get }
    func loadModel(from url: URL) async throws
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
    func unloadModel() async
}


// ═══════════════════════════════════════════════════════════════════
// MARK: - 1. llama.cpp via llama.swift (mattt)
// ═══════════════════════════════════════════════════════════════════
//
// SPM: .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.8209.0"))
// Module: LlamaSwift
//
// This wraps the raw llama.cpp C API exposed through the XCFramework.
// The API uses direct pointer access for batch fields (batch.token[i],
// batch.pos[i], etc.) and manual greedy sampling from logits.
//
// ┌─────────────────────────────────────────────────────────────────┐


import LlamaSwift

final class LlamaCppEngine: InferenceEngine, @unchecked Sendable {
    let name = "llama.cpp"
    
    private var model: OpaquePointer?   // llama_model *
    private var context: OpaquePointer? // llama_context *
    
    func loadModel(from url: URL) async throws {
        llama_backend_init()
        
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99  // offload all layers to Metal
        
        model = llama_model_load_from_file(url.path, modelParams)
        guard model != nil else {
            throw InferenceError.modelLoadFailed(url.lastPathComponent)
        }
        
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        
        context = llama_init_from_model(model, ctxParams)
        guard context != nil else {
            throw InferenceError.contextCreationFailed
        }
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let model else {
            throw InferenceError.modelNotLoaded
        }
        
        guard let vocab = llama_model_get_vocab(model) else {
            throw InferenceError.generationFailed("Failed to get vocabulary")
        }
        
        // Recreate context for each generation to start with a clean KV cache.
        // This matches the pattern in the llama.swift README.
        if let oldContext = context {
            llama_free(oldContext)
        }
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        guard let newContext = llama_init_from_model(model, ctxParams) else {
            throw InferenceError.contextCreationFailed
        }
        context = newContext
        
        let prompt = formatPrompt(messages)
        let promptTokens = tokenize(prompt, vocab: vocab)
        
        guard !promptTokens.isEmpty else {
            throw InferenceError.generationFailed("Tokenization produced no tokens")
        }
        
        // Create batch and fill with prompt tokens
        var batch = llama_batch_init(Int32(promptTokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        
        batch.n_tokens = Int32(promptTokens.count)
        for i in 0..<promptTokens.count {
            batch.token[i] = promptTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[i] {
                seqId[0] = 0
            }
            batch.logits[i] = 0
        }
        // Compute logits only for the last prompt token
        batch.logits[promptTokens.count - 1] = 1
        
        guard llama_decode(newContext, batch) == 0 else {
            throw InferenceError.decodeFailed
        }
        
        // Generate tokens
        var result = ""
        var nCur = batch.n_tokens
        let maxTokens: Int32 = 512
        let vocabSize = llama_vocab_n_tokens(vocab)
        let eosToken = llama_vocab_eos(vocab)
        
        for _ in 0..<maxTokens {
            // Greedy sampling: pick the token with the highest logit
            guard let logits = llama_get_logits_ith(newContext, batch.n_tokens - 1) else {
                break
            }
            
            var maxLogit = logits[0]
            var nextToken: llama_token = 0
            for i in 1..<Int(vocabSize) {
                if logits[i] > maxLogit {
                    maxLogit = logits[i]
                    nextToken = llama_token(i)
                }
            }
            
            // Check for end of sequence
            if nextToken == eosToken {
                break
            }
            
            // Convert token to text
            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, nextToken, &buf, Int32(buf.count), 0, false)
            if len > 0 {
                buf[Int(len)] = 0  // null-terminate
                let piece = String(cString: buf)
                result += piece
                onToken(piece)
            }
            
            // Prepare next batch with the single new token
            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[0] {
                seqId[0] = 0
            }
            batch.logits[0] = 1
            nCur += 1
            
            guard llama_decode(newContext, batch) == 0 else { break }
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
    
    private func tokenize(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + 1
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let n = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(maxTokens), true, true)
        guard n > 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }
    
    private func formatPrompt(_ messages: [ChatMessage]) -> String {
        // ChatML format — works with most instruct-tuned GGUF models
        var prompt = ""
        for msg in messages {
            let role = msg.role == .user ? "user" : "assistant"
            prompt += "<|im_start|>\(role)\n\(msg.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}


// └─────────────────────────────────────────────────────────────────┘


// ═══════════════════════════════════════════════════════════════════
// MARK: - 2. MLX Swift (Apple)
// ═══════════════════════════════════════════════════════════════════
//
// SPM: .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.30.1"))
// Products: MLXLLM, MLXLMCommon
//
// MLX models are directories with config.json + tokenizer.json +
// .safetensors files. SharedModelKit downloads them and provides
// the directory URL.
//
// ┌─────────────────────────────────────────────────────────────────┐


import MLX
import MLXLLM
import MLXLMCommon

final class MLXSwiftEngine: InferenceEngine, @unchecked Sendable {
    let name = "MLX Swift"
    
    private var modelContainer: ModelContainer?
    
    func loadModel(from url: URL) async throws {
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        
        // SharedModelKit provides a directory URL containing the MLX model files
        modelContainer = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: url)
        )
    }
    
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let modelContainer else {
            throw InferenceError.modelNotLoaded
        }
        
        let prompt = messages.map { msg in
            let role = msg.role == .user ? "user" : "assistant"
            return "<|im_start|>\(role)\n\(msg.content)<|im_end|>"
        }.joined(separator: "\n") + "\n<|im_start|>assistant\n"
        
        let generateParameters = GenerateParameters(temperature: 0.7, topP: 0.9)
        var result = ""
        
        try await modelContainer.perform { context in
            let input = try await context.processor.prepare(
                input: .init(prompt: .text(prompt))
            )
            
            try MLXLMCommon.generate(
                input: input,
                parameters: generateParameters,
                context: context
            ) { tokens in
                let fullText = context.tokenizer.decode(tokens: tokens)
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
// MARK: - Placeholder Engine (demo only — no real inference)
// ═══════════════════════════════════════════════════════════════════

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
            "Placeholder response — uncomment LlamaCppEngine (for GGUF) or MLXSwiftEngine (for MLX) in ChatViewModel and add the SPM dependency to get real inference with \(modelPath).",
            "SharedModelKit resolved \(modelPath). Wire up an inference engine to generate real responses.",
            "Running on-device with \(modelPath). Replace PlaceholderEngine with a real engine in ChatViewModel.swift.",
        ]
        let response = responses[abs(messages.last?.content.hashValue ?? 0) % responses.count]
        for word in response.split(separator: " ") {
            try await Task.sleep(for: .milliseconds(40))
            onToken(String(word) + " ")
        }
        return response
    }
    
    func unloadModel() async { modelPath = "" }
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
        case .modelNotLoaded:           return "No model loaded."
        case .modelLoadFailed(let n):   return "Failed to load model: \(n)"
        case .contextCreationFailed:    return "Failed to create inference context."
        case .decodeFailed:             return "Token decoding failed."
        case .generationFailed(let r):  return "Generation failed: \(r)"
        }
    }
}
