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

- iOS 16+
- Xcode 15+
- Swift 5.9+
- [SharedModelKit](https://github.com/Tschucker/SharedModelKit) (local or remote SPM dependency)

## Setup

### 1. Create an Xcode Project

Create a new **App** project in Xcode (SwiftUI, Swift). Name it `SharedModelChat`.

### 2. Add SharedModelKit

**From a local checkout:**

1. Drag the `SharedModelKit/` folder into the Xcode project navigator
2. Xcode recognizes the `Package.swift` and offers to add it
3. Go to your app target → General → Frameworks → `+` → select **SharedModelKit**

**From GitHub:**

Go to **File → Add Package Dependencies** → paste the SharedModelKit repo URL.

### 3. Add Source Files

Copy all `.swift` files from `SharedModelChat/SharedModelChat/` into your Xcode project. The files are:

| File | Description |
|---|---|
| `SharedModelChatApp.swift` | App entry point, creates the `ChatViewModel` environment object |
| `ContentView.swift` | Tab bar with Chat and Settings tabs |
| `ChatView.swift` | Message list, status banner, input bar, message bubbles |
| `ChatViewModel.swift` | Core logic — model status, download, engine routing, chat |
| `SettingsView.swift` | Folder picker, model selector, download metadata display |
| `ChatMessage.swift` | Message data model |
| `DesignSystem.swift` | Color palette, typography, and button styles |
| `InferenceEngine.swift` | Engine protocol + implementations for llama.cpp, MLX, and others |

### 4. Build and Run

The app runs immediately using the `PlaceholderEngine`, which returns simulated text responses. To use real inference, see [Enabling Inference Engines](#enabling-inference-engines) below.

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

The `InferenceEngine.swift` file contains complete implementations for five engines, all commented out behind `/* ... */` blocks ready to uncomment:

| Engine | Module | SPM Package | Best For |
|---|---|---|---|
| `LlamaCppEngine` | `LlamaSwift` | `mattt/llama.swift` | Full C API control over llama.cpp |
| `MLXSwiftEngine` | `MLXLLM`, `MLXLMCommon` | `ml-explore/mlx-swift-lm` | Fastest Metal-native MLX inference |
| `LocalLLMClientEngine` | `LocalLLMClient` | `tattn/LocalLLMClient` | Clean unified API for GGUF + MLX |
| `PlaceholderEngine` | (built-in) | — | Demo/development without dependencies |

### Enabling Inference Engines

#### Step 1: Add SPM Dependencies

For llama.cpp (GGUF models):

```swift
.package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.8209.0"))
```

For MLX Swift (MLX models):

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.30.1"))
```

#### Step 2: Uncomment the Engine

In `InferenceEngine.swift`, find the engine's `/* ... */` block and remove the comment delimiters.

#### Step 3: Set the Engine in ChatViewModel

```swift
// Replace:
private nonisolated(unsafe) let ggufEngine: any InferenceEngine = PlaceholderEngine()
private nonisolated(unsafe) let mlxEngine: any InferenceEngine = PlaceholderEngine()

// With:
private nonisolated(unsafe) let ggufEngine: any InferenceEngine = LlamaCppEngine()
private nonisolated(unsafe) let mlxEngine: any InferenceEngine = MLXSwiftEngine()
```

That's it. The `activeEngine` computed property handles routing based on the selected model's format.

### LlamaCppEngine Details

Uses the raw llama.cpp C API via the `LlamaSwift` module:

- Batch fields accessed via direct pointer indexing: `batch.token[i]`, `batch.pos[i]`, `batch.logits[i]`
- Context recreated before each generation for a clean KV cache
- Vocabulary accessed via `llama_model_get_vocab(model)` (returns optional, unwrapped with guard)
- Greedy sampling by iterating logits and selecting the argmax
- End-of-sequence detected via `llama_vocab_eos(vocab)`
- Token-to-text conversion via `llama_token_to_piece(vocab, token, ...)`
- Prompt formatting uses ChatML (`<|im_start|>user\n...<|im_end|>`)

### MLXSwiftEngine Details

Uses Apple's MLX framework via the `MLXLLM` and `MLXLMCommon` modules:

- Model loaded from a local directory via `LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: url))`
- SharedModelKit provides the directory URL (downloads the HuggingFace repo contents)
- Memory managed with `MLX.GPU.set(cacheLimit:)` for iOS
- Streaming via `MLXLMCommon.generate(input:parameters:context:)` with a callback
- Token decoding uses `context.tokenizer.decode(tokens:)` which returns cumulative text, diffed to extract new tokens

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
