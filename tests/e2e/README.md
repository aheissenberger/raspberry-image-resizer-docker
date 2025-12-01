# End-to-End Tests

Comprehensive E2E test suite for validating resize operations and compression workflows.

## Test Files

### `resize.test.ts`
Ported from `run-test.sh`. Tests core resize scenarios with Docker:

- **Test 1**: Boot expansion with root move (64MB→256MB boot, no image resize)
- **Test 2**: Image expansion with boot resize (700MB→1500MB image, 64MB→256MB boot)
- **Test 3**: Image shrink without boot change (700MB→600MB image, boot stays 64MB)

All tests validate that file contents are preserved using SHA256 snapshots.

### `compression.test.ts`
Ported from `test-compression.sh`. Tests compression support:

- **Tool Validation**: Verifies zstd, xz, gzip availability
- **Level Validation**: Tests compression level bounds (zstd: 1-19, xz/gzip: 1-9)
- **Compression Creation**: Creates and validates compressed images with all algorithms
- **Detection Tests**: Auto-detection of .zst/.xz/.gz extensions
- **Resize Compressed**: Tests resizing compressed images with auto-decompression
- **Checksum Verification**: Ensures original files remain unchanged

### `helpers.ts`
Shared utilities for E2E testing:

- Docker image building and container execution
- Snapshot comparison (SHA256 checksums)
- File compression helpers (zstd, xz, gzip)
- Test image creation
- Cleanup utilities

## Prerequisites

Before running E2E tests:

```bash
# Build the CLI executable
bun run build:cli

# Build Docker worker and image
bun run docker:build
```

Ensure Docker Desktop is running.

## Running Tests

```bash
# Run all E2E tests
bun run test:e2e

# Run specific test file
bun test tests/e2e/resize.test.ts --timeout=300000
bun test tests/e2e/compression.test.ts --timeout=300000
```

## Test Duration

- Resize tests: ~5 minutes per test (Docker image creation + partition manipulation)
- Compression tests: ~3 minutes per test (compression + CLI operations)
- Total E2E suite: ~15-20 minutes

## Test Artifacts

Tests create temporary files during execution:

- `test.img`, `test-expand.img`, `test-shrink.img` - Test disk images
- `test-compressed-*.img.*` - Compressed test images
- `snapshot-*.txt` - SHA256 checksums for file preservation validation
- `*.decompressed_*.img` - Temporary decompressed images

All artifacts are automatically cleaned up after tests complete.

## Migration Notes

### From Bash to TypeScript

The E2E tests were ported from bash scripts to Bun/TypeScript:

- **run-test.sh** → `tests/e2e/resize.test.ts`
- **test-compression.sh** → `tests/e2e/compression.test.ts`

Benefits:
- Type safety and better IDE support
- Integrated with Bun test runner
- Consistent test infrastructure with unit tests
- Async/await for process handling
- Better error messages and test output
- No external bash dependencies for test orchestration

The test infrastructure now runs entirely in TypeScript:
- `src/test-helper.ts` creates test images and orchestrates resize operations inside Docker
- `src/worker/worker.ts` performs the actual resize operations (replaces the bash worker script)
- All bash scripts have been eliminated from the test flow
