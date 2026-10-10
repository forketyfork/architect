# Development

This document covers local setup, build/test commands, and release steps.

## Prerequisites

- Nix with flakes enabled
- macOS: Xcode Command Line Tools if you plan to use Homebrew dependencies

## Setup

1. (Optional) Pre-fetch the ghostty dependency to speed up the first build:
   ```bash
   just setup
   ```
   `just setup` caches the `ghostty` source tarball; the regular build will fetch it automatically if you skip this step.

2. Enter the development shell:
   ```bash
   nix develop
   ```

   Or, if using direnv:
   ```bash
   direnv allow
   ```

   On macOS hosts where the active `MacOSX.sdk` only exposes `arm64e` targets, the Zig 0.16.0 dev shell retains a workaround for native Darwin linking errors such as `undefined symbol: __availability_version_check`. The upstream tracker for this regression is https://codeberg.org/ziglang/zig/issues/31756.

   If `MacOSX15.4.sdk` is installed, the dev shell can expose it through a fake `DEVELOPER_DIR` whose `usr/bin/xcrun` is a narrow shim for `xcrun --sdk macosx --show-sdk-path`. If that legacy SDK has been removed, the helper is a no-op and the build uses the active SDK instead. `build.zig` resolves the SDK through `SDKROOT`, `DEVELOPER_DIR`, `xcrun`, and known installation paths, then supplies its framework and system-library directories explicitly.

   Keep the workaround until a macOS host confirms that Zig handles the arm64e-only SDK stubs correctly. If the active `MacOSX.sdk/usr/lib/libSystem.tbd` advertises `arm64-macos` again, or the legacy 15.4 SDK is unavailable, the shell hook becomes a no-op. Newer SDK framework stubs may re-export `/usr/lib/libobjc.A.dylib`; the build links `objc` explicitly so Zig 0.16 can resolve that dependency from the selected SDK.

   The Homebrew formula sources the same helper while building from source, so Homebrew installs receive the SDK selection even though they do not run inside the Nix development shell.

3. Verify the environment:
   ```bash
   zig version  # Should show 0.16.0+ (compatible with ghostty-vt)
   just --list  # Show available commands
   ```

## Build and Run

Build the project:
```bash
just build
# or
zig build
```

Build optimized release:
```bash
zig build -Doptimize=ReleaseFast
```

Run the application:
```bash
just run
# or
zig build run
```

Run with a custom log directory (see `docs/configuration.md` for logging details):
```bash
just run --log-dir .tmp/architect-debug-logs
# or
zig build run -- --log-dir .tmp/architect-debug-logs
```

## Dependencies and Tooling

- **ghostty-vt** is fetched as a pinned tarball via the Zig package manager (`build.zig.zon`).
- **Zwanzig v0.15.1** is pinned as a Zig build dependency and runs as a host-targeted `ReleaseFast` build tool through `zig build lint`. Architect passes its requested target architecture and operating system to Zwanzig for target-aware analysis.
- **SDL3** and **SDL3_ttf** are provided by Nix. SDL3 is pinned to 3.4.10 via `overlays/sdl3-3-4-10.nix` with binaries cached in the public `forketyfork` Cachix to avoid rebuilds.

SDL3 and the platform C APIs are translated at build time with Zig's built-in
`addTranslateC` steps using the small header shims under `src/c/`. When SDL is
provided outside the compiler's default search paths, `SDL3_INCLUDE_PATH` and
`SDL3_TTF_INCLUDE_PATH` supply the include paths to both translation and
compilation. The Homebrew formula sets these variables from the installed SDL
formula prefixes before starting the build. On macOS, framework headers use
the SDK path discovered from `SDKROOT`, `DEVELOPER_DIR`, or `xcrun`, in that
order. The macOS cwd query uses a narrow declaration in `src/c/libproc.h` and
the compiled `src/c/libproc.c` wrapper rather than translating Apple's full
Mach/libproc header tree, whose layout is incompatible with Zig 0.16 and the
new SDK headers.

## Tests and Formatting

Run tests:
```bash
just test
# or
zig build test
```

Tests live next to the code they cover. Zig only collects tests from files it
actually analyzes, so **a new file with tests must be listed in the
`test { _ = @import(...); }` block at the bottom of `src/main.zig`** — otherwise
its tests compile but silently never run. `scripts/check-test-registry.sh`
(part of `just lint`) fails the build when a file with tests is missing from
that block.

The MCP test binary drives a complete stdio `tools/call` request against an
isolated runtime directory and verifies the structured error returned when
Architect is not running. This also covers environment initialization before
control-socket discovery.

Keyboard regression tests cover all combinations of Shift, Ctrl, Option, and
Command on navigation and function keys in normal/application cursor modes and
legacy/Kitty encoding. They also verify exact app shortcuts, compatibility
bindings with left/right/both-side SDL modifiers, negotiated terminal options,
and Kitty press/repeat/release actions. Pipe-backed input tests verify event
delivery, press ownership across focus changes, invalidation on session restart,
and deferred Escape tap/hold behavior. Extend this coverage when adding a key
mapping or shortcut; use side-specific SDL masks to model real keyboard events.

Check formatting and script linting:
```bash
just lint
# or
zig fmt --check src/
shellcheck scripts/*.sh scripts/verify-setup.sh
ruff check scripts/*.py
```

Format code:
```bash
zig fmt src/
```

## Release Process

macOS release binaries are automatically built for both ARM64 (Apple Silicon) and x86_64 (Intel) architectures via GitHub Actions when a version tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow signs each app bundle with a Developer ID Application certificate (hardened runtime + secure timestamp) and submits it to Apple's notary service before packaging, using [`scripts/bundle-macos.sh`](../scripts/bundle-macos.sh) and [`scripts/notarize-macos.sh`](../scripts/notarize-macos.sh). The workflow fails fast if the required secrets (below) are not configured — this applies to `workflow_dispatch` runs too, so a maintainer without the secrets set up cannot produce a release build. Local/dev use of `scripts/bundle-macos.sh` is unaffected: without `APPLE_SIGNING_IDENTITY` set, it still ad-hoc signs (`codesign --sign -`) as before.

Each release includes:
- `architect-macos-arm64.tar.gz` - Apple Silicon
- `architect-macos-x86_64.tar.gz` - Intel

Each archive contains `Architect.app` with both `Contents/MacOS/architect` and the stdio MCP helper `Contents/MacOS/architect-mcp`, notarized and stapled so Gatekeeper accepts them without clearing the quarantine attribute.

### Code Signing and Notarization Setup

The release workflow requires these GitHub Actions repository secrets:

| Secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate + private key (`.p12`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Certificate common name, e.g. `Developer ID Application: Jane Doe (TEAMID1234)` |
| `APPLE_KEYCHAIN_PASSWORD` | Password for the temporary CI keychain (any random string; only used within the job) |
| `APPLE_API_KEY_ID` | Key ID of an App Store Connect API key used for notarization |
| `APPLE_API_ISSUER_ID` | Issuer ID for the same API key |
| `APPLE_API_KEY_P8` | Full contents of the API key's `.p8` file |

One-time setup, assuming an active Apple Developer Program membership:

1. **Create the Developer ID Application certificate.**
   - Open Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority, save the CSR to disk.
   - In [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list), create a new certificate, choose **Developer ID Application**, and upload the CSR.
   - Download the issued certificate and double-click it to install it into your login keychain.
2. **Export it as a `.p12`.**
   - In Keychain Access, find the certificate (it will show a disclosure triangle with the matching private key underneath), select both the certificate and the key, right-click → Export 2 items…
   - Save as `architect-signing.p12` and set an export password — this becomes `APPLE_CERTIFICATE_PASSWORD`.
3. **Base64-encode the `.p12`** for storage as a secret:
   ```bash
   base64 -i architect-signing.p12 | pbcopy
   ```
   Paste the result as `APPLE_CERTIFICATE_P12`.
4. **Determine the signing identity string:**
   ```bash
   security find-identity -v -p codesign
   ```
   Copy the quoted name (e.g. `Developer ID Application: Jane Doe (TEAMID1234)`) as `APPLE_SIGNING_IDENTITY`.
5. **Create an App Store Connect API key for notarization.**
   - Go to [App Store Connect → Users and Access → Integrations → Team Keys](https://appstoreconnect.apple.com/access/integrations/api).
   - Create a new key with the **Developer** role (sufficient for notarization).
   - Download the `.p8` file immediately — it can only be downloaded once. Its contents become `APPLE_API_KEY_P8`.
   - Note the **Key ID** (`APPLE_API_KEY_ID`) and **Issuer ID** (`APPLE_API_ISSUER_ID`) shown on the same page.
6. **Pick a random string** for `APPLE_KEYCHAIN_PASSWORD` (e.g. `openssl rand -base64 32`); it only protects the ephemeral keychain created during the CI job.
7. **Add all seven secrets** under the repository's Settings → Secrets and variables → Actions.
8. Verify by running the Release workflow manually (`workflow_dispatch`) before pushing a real tag, or by pushing a tag once satisfied.

Delete the local `.p12`/CSR files after uploading the secrets — the CI keychain that imports the certificate is created fresh and deleted at the end of every job run.
