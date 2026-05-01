# SharedModelChat

A reference iOS chat application demonstrating how to integrate [SharedModelKit](https://github.com/Tschucker/SharedModelKit) for shared on-device AI model management. The app includes a clean conversational interface, model selection across GGUF and MLX formats, automatic engine switching, and full download lifecycle management.

## Purpose

This app exists to show other developers how to:

1. Set up SharedModelKit with a `BookmarkBackend` for cross-app model sharing
2. Display model status (`ModelStatus`) in a reactive SwiftUI interface
3. Download and manage both GGUF and MLX models through the framework
4. Route models to the correct inference engine based on format
5. Wire up the inference engine protocol to stream tokens into a chat UI

The app compiles and runs as-is using a `PlaceholderEngine`. To enable real inference, uncomment one of the provided engine implementations and add its SPM dependency.

## Screenshots

The app has two tabs:

- **Chat** — a conversational interface with streaming message bubbles, a model status banner, and keyboard-dismissing scroll behavior
- **Settings** — shared folder picker, model selector grouped by format, live download progress, metadata display with download date, and HuggingFace links

## Requirements

- iOS 18+
- Xcode 16+
- Swift 6+

## Setup

### Creating a New Project

1. Create a new **App** project in Xcode (SwiftUI, Swift). Name it `SharedModelChat`.
2. Add all `.swift` files from `SharedModelChat/SharedModelChat/` to your target.
3. Add the package dependencies below.
4. Build and run.

### Package Dependencies

**SharedModelKit** (required — model storage, discovery, download, status):

Add via **File → Add Package Dependencies** using the [SharedModelKit](https://github.com/Tschucker/SharedModelKit) repo URL, or drag a local checkout into the project navigator and link **SharedModelKit** under your target's Frameworks.

**LlamaSwift** (required for GGUF inference):

```
https://github.com/mattt/llama.swift  —  up to next major from 2.8676.0
```

Add product: `LlamaSwift`

**MLX Swift** (required for MLX inference):

```
https://github.com/ml-explore/mlx-swift-lm  —  up to next major from 2.31.3
```

Add products: `MLXLLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXVLM`

> To build without the inference dependencies, swap both engines to `PlaceholderEngine` in `ChatViewModel.swift` — see [Inference Engines](#inference-engines) for details.

## Architecture

### Data Flow

```
User selects folder → BookmarkBackend saves bookmark
                           ↓
User selects model  → ChatViewModel.didChangeModel()
                           ↓
                      store.status(of: descriptor) → ModelStatus
                           ↓
                      store.metadata(for: descriptor) → downloadDate
                           ↓
                      UI updates (banner, settings card)
                           ↓
User taps Download  → store.modelURL(for: descriptor, progress:)
                           ↓
                      SharedModelKit downloads to:
                      <shared_folder>/<format>/<model_folder>/
                           ↓
                      loadIntoEngine(url:) → engine.loadModel(from:)
                           ↓
User sends message  → engine.generate(messages:, onToken:)
                           ↓
                      Tokens stream into ChatMessage via @Published
```

### ChatViewModel

The view model is the central coordinator. Key responsibilities:

**SharedModelKit integration:**

```swift
// Store with fallback chain
store = ModelStore(backends: [bookmarkBackend, LocalDirectoryBackend()])
await store.register(ModelCatalog.all)

// Reactive status
let status = await store.status(of: descriptor)
let metadata = await store.metadata(for: descriptor)

// Download (handles both GGUF and MLX)
let url = try await store.modelURL(for: descriptor) { received, total in
    // progress callback → updates ModelStatus.downloading
}
```

**Automatic engine switching:**

```swift
private var activeEngine: any InferenceEngine {
    switch selectedModel.format {
    case .mlx: return mlxEngine
    default:   return ggufEngine
    }
}
```

When the user picks a GGUF model, the view model routes to `ggufEngine`. When they pick an MLX model, it routes to `mlxEngine`. On model switch, both engines are unloaded to free memory.

**Auto-load on discovery:**

When `refreshStatus()` finds a model already on disk (from a previous session or downloaded by another app), it automatically calls `engine.loadModel(from:)` so the user can start chatting immediately.

### ChatView

The chat view uses `ModelStatus` directly from SharedModelKit to render the status banner:

```swift
switch viewModel.modelStatus {
case .unavailable:          // "Select a shared folder"
case .notDownloaded:        // "Model not found" + Download button
case .downloading(let p, let r, let t):  // Progress bar + byte counts
case .ready(let url, let size):          // Hidden (model loaded)
case .error(let msg):       // Error message + Retry button
}
```

The header shows the loaded model filename and file size when ready. The send button is disabled unless `modelStatus.isReady && !isGenerating`.

### SettingsView

**Current model card:** Shows the selected model name, format badge (GGUF/MLX), status with download progress or file size, download date from `ModelDownloadMetadata`, and a delete button.

**Model selector:** Groups models into GGUF and MLX sections. Each row displays the model name, format badge (green for MLX, taupe for GGUF), quantization tag, and size. Tapping a model calls `didChangeModel()` which unloads engines and refreshes status.

**HuggingFace links:** Direct links to each model's HuggingFace page for manual download.

### Design System

The app uses a warm, muted color palette:

| Token | Hex | Usage |
|---|---|---|
| `Chat.canvas` | `#F5F1EB` | Main background |
| `Chat.surface` | `#EDEAE4` | Header, input bar |
| `Chat.userBubble` | `#3C3A36` | User message bubble (warm charcoal) |
| `Chat.aiBubble` | `#E8E4DD` | AI message bubble (warm light grey) |
| `Chat.accent` | `#9B8B7A` | Buttons, interactive elements (taupe) |
| `Chat.success` | `#7A9B7E` | Ready status, MLX badge (sage) |
| `Chat.error` | `#B07A7A` | Error states (muted rose) |
| `Chat.textPrimary` | `#2C2A26` | Main text, input field text |
| `Chat.textSecondary` | `#8A857D` | Captions, timestamps |

Typography uses `Font.system` with `.rounded` design for headings and `.monospaced` for model labels.

## Inference Engines

The `InferenceEngine` protocol defines the interface between SharedModelKit's file URLs and actual token generation:

```swift
protocol InferenceEngine: Sendable {
    var name: String { get }
    func loadModel(from url: URL) async throws
    func generate(
        messages: [ChatMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
    func unloadModel() async
}
```

### Available Implementations

| Engine | Module | SPM Package | Format |
|---|---|---|---|
| `LlamaCppEngine` | `LlamaSwift` | `mattt/llama.swift` | GGUF |
| `MLXSwiftEngine` | `MLXLLM`, `MLXLMCommon` | `ml-explore/mlx-swift-lm` | MLX |
| `PlaceholderEngine` | (built-in) | — | Any (simulated responses) |

Both real engines are active by default. `ChatViewModel` selects between them via the `activeEngine` computed property, routing MLX-format models to `MLXSwiftEngine` and everything else to `LlamaCppEngine`.

To build without the heavy SPM dependencies, swap either engine back to `PlaceholderEngine` in `ChatViewModel.swift`:

```swift
private nonisolated(unsafe) let ggufEngine: any InferenceEngine = PlaceholderEngine()
private nonisolated(unsafe) let mlxEngine: any InferenceEngine = PlaceholderEngine()
```

### LlamaCppEngine Details

Uses the raw llama.cpp C API via the `LlamaSwift` module (`mattt/llama.swift`):

- All layers offloaded to Metal (`n_gpu_layers = 99`), context window 2048, batch size 512
- Context is recreated before each generation for a clean KV cache
- Vocabulary via `llama_model_get_vocab(model)`; EOS detected via `llama_vocab_eos(vocab)`
- Greedy sampling — iterates logits array and picks argmax
- Token decoding via `llama_token_to_piece(vocab, token, ...)`
- Prompt formatted as ChatML (`<|im_start|>role\n...<|im_end|>`)
- Max 512 generated tokens per turn

### MLXSwiftEngine Details

Uses Apple's MLX framework via `MLXLLM` and `MLXLMCommon` (`ml-explore/mlx-swift-lm`):

- GPU cache capped at 20 MB via `MLX.GPU.set(cacheLimit:)` before loading
- Model loaded from the directory URL SharedModelKit provides: `LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: url))`
- Input prepared with `context.processor.prepare(input: .init(prompt: .text(prompt)))`
- Generation parameters: `temperature: 0.7`, `topP: 0.9`, max 512 tokens
- `MLXLMCommon.generate` callback receives cumulative token arrays; new text is extracted by diffing against the previous decoded length
- Prompt formatted as ChatML

## Available Models

The demo app exposes all models from `ModelCatalog.all`:

### GGUF Models (for llama.cpp)

| Name | Size | Quantization | HuggingFace |
|---|---|---|---|
| Llama 3.2 1B Instruct | ~808 MB | Q4_K_M | [bartowski/Llama-3.2-1B-Instruct-GGUF](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) |
| Llama 3.2 3B Instruct | ~2.0 GB | Q4_K_M | [bartowski/Llama-3.2-3B-Instruct-GGUF](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF) |
| Gemma 2 2B Instruct | ~1.5 GB | Q4_K_M | [bartowski/gemma-2-2b-it-GGUF](https://huggingface.co/bartowski/gemma-2-2b-it-GGUF) |
| Phi-3 Mini 4K Instruct | ~2.4 GB | Q4_K_M | [bartowski/Phi-3-mini-4k-instruct-GGUF](https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF) |
| Mistral 7B Instruct v0.3 | ~4.4 GB | Q4_K_M | [bartowski/Mistral-7B-Instruct-v0.3-GGUF](https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF) |

### MLX Models (for MLX Swift / Metal)

| Name | Size | Quantization | HuggingFace |
|---|---|---|---|
| Llama 3.2 1B Instruct (MLX) | ~0.7 GB | 4-bit | [mlx-community/Llama-3.2-1B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) |
| Llama 3.2 3B Instruct (MLX) | ~1.8 GB | 4-bit | [mlx-community/Llama-3.2-3B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) |
| Gemma 3 1B Instruct (MLX) | ~0.6 GB | 4-bit | [mlx-community/gemma-3-1b-it-4bit](https://huggingface.co/mlx-community/gemma-3-1b-it-4bit) |
| Qwen3 4B (MLX) | ~2.5 GB | 4-bit | [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) |
| Mistral 7B Instruct v0.3 (MLX) | ~4.0 GB | 4-bit | [mlx-community/Mistral-7B-Instruct-v0.3-4bit](https://huggingface.co/mlx-community/Mistral-7B-Instruct-v0.3-4bit) |

## Project Structure

```
SharedModelChat/
└── SharedModelChat/
    ├── SharedModelChatApp.swift   # @main entry, creates ChatViewModel
    ├── ContentView.swift             # TabView (Chat, Settings)
    ├── ChatView.swift                # Messages, status banner, input bar
    ├── ChatViewModel.swift           # Model management, engine routing, chat
    ├── SettingsView.swift            # Folder picker, model list, metadata
    ├── ChatMessage.swift             # Message model (id, role, content, streaming)
    ├── DesignSystem.swift            # Colors, fonts, button styles
    └── InferenceEngine.swift         # Protocol + llama.cpp, MLX, LocalLLMClient
```

## Customization

### Adding a New Model

1. Add a `ModelDescriptor` to `ModelCatalog` in SharedModelKit (or define one locally)
2. Add a `SelectableModel.from(...)` entry to the `availableModels` array in `ChatViewModel.swift`

### Adding a New Inference Engine

1. Implement the `InferenceEngine` protocol
2. Add it as a property in `ChatViewModel`
3. Update the `activeEngine` computed property to route the correct format to your engine

### Changing the Color Palette

Edit `DesignSystem.swift`. All colors are defined as static properties on `Color.Chat` using hex values.

## License

MIT
