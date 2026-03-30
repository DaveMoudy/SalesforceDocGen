# Contributing to Portwood DocGen

Thanks for your interest in contributing! DocGen is a community-driven Salesforce document generation tool, and contributions of all kinds are welcome — bug fixes, features, documentation, template examples, and testing.

## Getting Started

### Prerequisites

- Salesforce CLI (`sf`) installed
- A Salesforce DevHub org (or use a Developer Edition org)
- Git

### Local Setup

1. **Fork and clone** this repo
2. **Create a scratch org:**
   ```bash
   sf org create scratch --definition-file config/project-scratch-def.json --alias docgen-dev --set-default --duration-days 30
   ```
3. **Push source:**
   ```bash
   sf project deploy start --target-org docgen-dev
   ```
4. **Assign permission set:**
   ```bash
   sf org assign permset --name DocGen_Admin --target-org docgen-dev
   ```
5. **Enable the Release Update:** Setup > Release Updates > "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations" > Enable
6. **Run E2E tests** to verify:
   ```bash
   sf apex run --target-org docgen-dev -f scripts/e2e-test.apex
   ```

You should see `PASS: 23  FAIL: 0  ALL TESTS PASSED`.

## How to Contribute

### Reporting Bugs

[Open a bug report](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/new?template=bug_report.md). Include your package version, Salesforce edition, and steps to reproduce. Screenshots and error messages help a lot.

### Suggesting Features

[Open a feature request](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/new?template=feature_request.md) or start a [Discussion](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/discussions) to talk through the idea first.

### Submitting Code

1. **Check existing issues** — is someone already working on this?
2. **Open an issue first** for non-trivial changes so we can align on approach
3. **Fork the repo** and create a branch from `main`
4. **Make your changes** — follow the guidelines below
5. **Run all tests** — E2E and Apex unit tests must pass
6. **Open a PR** against `main` with a clear description

### Code Guidelines

- **Read CLAUDE.md** before making changes to the merge engine or PDF pipeline. It documents critical constraints (relative image URLs, zero-heap rendering, no VersionData in PDF queries).
- **Run the E2E test script** after every change. If you add a feature, add a test for it.
- **Run Code Analyzer:** `sf code-analyzer run --rule-selector "recommended" --target force-app` — 0 Critical, 0 High required.
- **No external dependencies.** DocGen is 100% native Apex + LWC. No npm packages, no external APIs, no callouts.
- **No e-signatures.** This was intentionally removed — see CLAUDE.md for the rationale.
- **Use `WITH USER_MODE`** or `Security.stripInaccessible()` for all SOQL/DML in user-facing code.
- **Namespace awareness:** Source code does not use namespace prefixes. The platform resolves `portwoodglobal__` at compile time.

### What Makes a Good PR

- **Small and focused.** One bug fix or one feature per PR.
- **Tests included.** E2E assertions for new behavior, Apex tests for new methods.
- **Clear description.** What changed, why, and how you tested it.
- **No unrelated changes.** Don't refactor surrounding code or add comments to files you didn't change.

## Architecture Overview

If you're new to the codebase, start here:

| Class | What It Does |
|-------|-------------|
| `DocGenService` | Core merge engine — template parsing, tag replacement, image handling, PDF rendering |
| `DocGenHtmlRenderer` | Converts DOCX XML to HTML for `Blob.toPdf()` |
| `DocGenDataRetriever` | Multi-level SOQL with V1/V2/V3/V4 query config routing |
| `DocGenController` | LWC controller — template CRUD, generation endpoints |
| `BarcodeGenerator` | Pure Apex Code 128 + QR code generation |
| `DocGenBatch` | Batch Apex for bulk document generation |

Client-side (LWC):
| Component | What It Does |
|-----------|-------------|
| `docGenRunner` | Main record page component — template selection, generation, PDF merge |
| `docGenAdmin` | Template manager — create, edit, version, query builder |
| `docGenColumnBuilder` | Visual query builder with tree visualization |
| `docGenPdfMerger` | Client-side PDF merge engine (pure JS) |
| `docGenZipWriter` | Client-side DOCX/XLSX assembly (pure JS) |

## Community

- **Issues:** Bug reports, feature requests, and questions
- **Discussions:** General conversation, ideas, show-and-tell, template sharing
- **Community Hub:** [portwoodglobalsolutions.com/DocGenCommunity](https://portwoodglobalsolutions.com/DocGenCommunity) — forum with real-time help

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
