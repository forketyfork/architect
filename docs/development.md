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

   On macOS hosts where the active `MacOSX.sdk` only exposes `arm64e` targets, Zig 0.15.2 can fail during native Darwin linking with errors such as `undefined symbol: __availability_version_check`. The upstream tracker for this regression is https://codeberg.org/ziglang/zig/issues/31756.

   The dev shell works around that by exposing `MacOSX15.4.sdk` through a fake `DEVELOPER_DIR` whose `usr/bin/xcrun` is a narrow shim for `xcrun --sdk macosx --show-sdk-path`. `build.zig` also resolves framework paths through `DEVELOPER_DIR` and `xcrun` before it falls back to hardcoded SDK locations, so the workaround does not need to force `SDKROOT`. Keeping the shim inside the fake developer tree means tools like `git` can still invoke `/usr/bin/xcrun` without tripping over the overridden `DEVELOPER_DIR`.

   Remove this workaround once Architect no longer uses Zig 0.15.2, or once Zig handles the arm64e-only macOS SDK stubs correctly. If the active `MacOSX.sdk/usr/lib/libSystem.tbd` advertises `arm64-macos` again, the shell hook becomes a no-op.

3. Verify the environment:
   ```bash
   zig version  # Should show 0.15.2+ (compatible with ghostty-vt)
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

## Dependencies and Tooling

- **ghostty-vt** is fetched as a pinned tarball via the Zig package manager (`build.zig.zon`).
- **Zwanzig** is pinned as a Zig build dependency and runs as a host-targeted `ReleaseFast` build tool through `zig build lint`. Architect passes its requested target architecture and operating system to Zwanzig for target-aware analysis.
- **SDL3** and **SDL3_ttf** are provided by Nix. SDL3 is pinned to 3.4.10 via `overlays/sdl3-3-4-10.nix` with binaries cached in the public `forketyfork` Cachix to avoid rebuilds.

## Tests and Formatting

Run tests:
```bash
just test
# or
zig build test
```

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
