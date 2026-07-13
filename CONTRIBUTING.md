# Contributing to KasetPlus

Thank you for your interest in contributing! We welcome all contributions.

## Getting Started

### Requirements

- macOS 26.0 or later
- Xcode 16.0 or later
- Swift 6.0

### Setup

```bash
git clone https://github.com/Yoddikko/kasetPlus.git
cd kasetPlus

# Build
swift build

# Run tests (do not combine with UI tests)
swift test --skip KasetUITests

# Lint & Format
swiftlint --strict && swiftformat .
```

## Project Structure

```
Sources/
  └── Kaset/               → Main app
      ├── Models/          → Data models
      ├── Services/        → API, Auth, Player, WebKit
      ├── ViewModels/      → Music & YouTube logic
      ├── Utilities/       → Logging, extensions
      └── Views/           → SwiftUI UI
Tests/                     → Unit tests
Scripts/                   → Build scripts
docs/                      → Documentation
```

## Coding Guidelines

### Swift & SwiftUI

| ❌ Avoid | ✅ Use |
|----------|--------|
| `print()` | `DiagnosticsLogger` |
| `DispatchQueue` | `async`/`await` |
| Force unwraps (`!`) | Optional handling |
| `.foregroundColor()` | `.foregroundStyle()` |

### Swift Concurrency

- Mark `@Observable` classes with `@MainActor`
- Use `async`/`await` everywhere
- Never use `DispatchQueue`

### WebKit

- Use `WebKitManager`'s shared `WKWebsiteDataStore` for cookies
- Use `SingletonPlayerWebView.shared` for playback (never create multiple WebViews)

### No Third-Party Frameworks

Do not add third-party dependencies without discussion first.

## Pull Request Checklist

- [ ] `swift build` passes
- [ ] `swift test --skip KasetUITests` passes
- [ ] `swiftlint --strict && swiftformat .` runs clean
- [ ] Changes are focused and reviewable
- [ ] If using AI assistance, include the prompt in PR description

## Testing

```bash
# Run unit tests
swift test --skip KasetUITests

# Run specific test
swift test --skip KasetUITests --filter PlayerServiceTests
```

See [docs/testing.md](docs/testing.md) for more details.

## Questions?

Open a GitHub Discussion or email alessioiodiceuni@gmail.com

---

**Thank you for contributing to KasetPlus!** 🎵
