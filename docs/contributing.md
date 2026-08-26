# Contributing to GitZ

Thank you for your interest in contributing to GitZ!

## Getting Started

### Prerequisites

- **Zig 0.16+** — [Download](https://ziglang.org/download/)
- **git** — For cloning and pushing
- A GitHub account

### Setup

```bash
# Fork the repository on GitHub

# Clone your fork
git clone git@github.com:YOUR_USERNAME/gitz.git
cd gitz

# Build
zig build

# Run tests
zig build test

# Verify
./zig-out/bin/gitz --version
```

## Development Workflow

### Building

```bash
# Debug build (fast compile, no optimizations)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run specific tests
zig build test -- --test-filter "sha1"
zig build test -- --test-filter "delta"
```

### Code Structure

```
src/
├── main.zig              # Entry point
├── cli/
│   ├── mod.zig           # Command dispatcher
│   ├── parser.zig        # Argument parser
│   └── commands/         # Command implementations
├── core/                 # Git object model + storage
├── transport/            # HTTP/SSH transports
└── util/                 # I/O and UI helpers
```

### Adding a New Command

1. Create `src/cli/commands/mycommand.zig`
2. Add `pub fn execute(allocator, git_dir, args, io) !void { ... }`
3. Register in `src/cli/mod.zig` dispatch
4. Add comptime import in `src/main.zig`
5. Add shell completions in `completions/`

### Code Style

- **Zig idioms:** Use `try` for error handling, `defer` for cleanup
- **Memory:** Always pair allocations with `defer allocator.free()`
- **Error messages:** Use `io.eprint` for user-facing errors
- **Colors:** Use `ui.c.*` constants, not raw ANSI codes
- **Tests:** Add `test "name" { ... }` blocks in each module

### Testing

```bash
# Run all tests
zig build test

# Run a specific test
zig build test -- --test-filter "sha1"

# Run E2E compatibility tests
zig build test -- --test-filter "compat"
```

### Commit Messages

Follow conventional commits:

```
feat: add gitz bisect command
fix: resolve delta chain depth limit
docs: update installation guide
refactor: extract common ref resolution logic
test: add unit tests for pkt-line parsing
```

### Pull Request Process

1. Create a feature branch (`git checkout -b feature/amazing`)
2. Make your changes
3. Run `zig build test` — all tests must pass
4. Commit with a descriptive message
5. Push to your fork (`git push origin feature/amazing`)
6. Open a Pull Request

## Architecture Principles

### 1. Git Compatibility First

All objects must be 100% compatible with real git. If in doubt, check with `git fsck`.

### 2. Zero External Dependencies

GitZ should compile and run with only Zig. No git binary required for local operations.

### 3. Performance Matters

Use `mmap` for large files, parallel operations where possible, and avoid unnecessary allocations.

### 4. Clean Error Handling

Every error should produce a helpful message. Never silently fail.

### 5. Simple APIs

Each module should have a clear, focused responsibility. Avoid god objects.

## Reporting Bugs

Open an issue on GitHub with:

1. **Description:** What happened vs. what you expected
2. **Steps to reproduce:** Minimal commands to trigger the bug
3. **Environment:** OS, Zig version, GitZ version
4. **Output:** Any error messages or unexpected behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
