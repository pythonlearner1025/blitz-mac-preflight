# blitz-macos CI/CD Migration Plan

**Source of truth for migrating the blitz-cn npm-based release pipeline to blitz-macos (native Swift).**

---

## Context

`blitz-cn` was a Tauri (Rust + TypeScript) app with a fully built npm-based CI/CD pipeline:
- `npm version patch` for version bumps
- `tauri build` → `.app`
- `build-pkg.sh` → signed + notarized `.pkg`
- `deploy-pkg.sh` → upload to Cloudflare R2
- `preinstall` / `postinstall` scripts for user environment setup

`blitz-macos` is a native Swift macOS app (Swift Package Manager, no Tauri). The Node.js sidecar is still needed at runtime. The goal is to reuse as much of the existing release infrastructure as possible.

---

## Architecture: What Changed vs What Stayed

| Component | blitz-cn | blitz-macos |
|---|---|---|
| App build | `tauri build` | `swift build -c release` + `bundle.sh` |
| App source path | `src-tauri/target/release/bundle/macos/Blitz.app` | `.build/Blitz.app` |
| Bundle ID | `dev.blitz.mac` | `com.blitz.macos` |
| Version source | `package.json` (npm) | `package.json` (thin wrapper) |
| Node.js sidecar | bundled via tauri resources | bundled into `Blitz.app/Contents/Resources/dist/server/` |
| Sidecar build | `scripts/build-server.mjs` (builds from `server/`) | same script, references server source |
| PKG creation | `scripts/build-pkg.sh` | ported, Swift paths |
| Deploy | `scripts/deploy-pkg.sh` | ported, same R2 infra |
| preinstall | `src-tauri/pkg-scripts/preinstall` | `scripts/pkg-scripts/preinstall` (update bundle ID) |
| postinstall | `src-tauri/pkg-scripts/postinstall` | `scripts/pkg-scripts/postinstall` (nearly verbatim) |
| CI/CD trigger | `npm run release-tag` | `npm run release-tag` (same command, different build steps) |

---

## The `release-tag` Command

The old command was:
```
npm version patch && tauri build && npm run build:pkg && bash scripts/deploy-pkg.sh
```

The new command (same `npm run release-tag`):
```
npm version patch && npm run build:sidecar && npm run build:app && npm run build:pkg && npm run deploy
```

A thin `package.json` (no frontend deps, just dev tools + scripts) keeps `npm version patch` working as the version source of truth. All other scripts read the version from `package.json`.

---

## Files To Create / Modify

### New files
1. `package.json` — thin npm wrapper (version management + release scripts)
2. `CHANGELOG.md` — required by deploy-pkg.sh (version → release notes)
3. `scripts/build-server.mjs` — Node.js sidecar bundler (adapted from blitz-cn)
4. `scripts/build-pkg.sh` — macOS .pkg creator (adapted from blitz-cn, Swift paths)
5. `scripts/deploy-pkg.sh` — Cloudflare R2 uploader (adapted from blitz-cn)
6. `scripts/Entitlements.plist` — code signing entitlements for the Swift app
7. `scripts/pkg-scripts/preinstall` — PKG preinstall (adapted, update bundle ID)
8. `scripts/pkg-scripts/postinstall` — PKG postinstall (nearly verbatim from blitz-cn)

### Modified files
9. `scripts/bundle.sh` — add version injection from package.json, sidecar copy, deep signing
10. `Sources/BlitzApp/Services/NodeSidecarService.swift` — add `~/.blitz/node-runtime/bin/node` to search paths

---

## Decisions & Notes

### Version management
`package.json` is the single source of truth. `npm version patch` bumps it, and all build/deploy scripts read from it via:
```bash
VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
```

### Node.js sidecar source
The server bundled into the `.app` comes from `../blitz-cn/server/` by default (the known-working server implementation). The `NodeSidecarService.swift` API calls map directly to routes in that server. When a dedicated `blitz-macos` server is ready, update `SERVER_SRC_DIR` in `build-server.mjs`.

### Node.js runtime location
The `postinstall` script installs Node.js to `~/.blitz/node-runtime/bin/node`. `NodeSidecarService.swift` must check that path (in addition to `/usr/local/bin/node` etc.).

### Bundle ID change
Old: `dev.blitz.mac` → New: `com.blitz.macos`
- Update in `preinstall` (TCC reset line)
- Update in `deploy-pkg.sh` (used for R2 prefix path)
- `build-pkg.sh` reads identifier from `Info.plist` in the built `.app`

### Entitlements
The Swift app needs hardened runtime exceptions for the Node.js sidecar (JIT, unsigned memory, library validation). These are set in `scripts/Entitlements.plist` and applied both by `bundle.sh` (dev builds) and `build-pkg.sh` (distribution builds).

### Environment variables required for release
```
APPLE_SIGNING_IDENTITY=Developer ID Application: Your Name (YOUR_TEAM_ID)
APPLE_INSTALLER_IDENTITY=Developer ID Installer: Your Name (YOUR_TEAM_ID)
APPLE_API_KEY=<your App Store Connect API key ID>
APPLE_API_KEY_PATH=~/path/to/AuthKey_XXXXXXXXXX.p8
APPLE_API_ISSUER=<issuer UUID>
CLOUDFLARE_ACCOUNT_ID=<id>
R2_ACCESS_KEY_ID=<key>
R2_SECRET_ACCESS_KEY=<secret>
R2_BUCKET=blitzapp-releases-1
```
Store in `.env` at project root (gitignored).

---

## Release Workflow

```
npm run release-tag
  ├── npm version patch               # bumps package.json, creates git tag
  ├── npm run build:sidecar           # scripts/build-server.mjs
  │     └── bundles Node.js server → dist/server/ (with pre-installed node_modules)
  ├── npm run build:app               # scripts/bundle.sh release
  │     ├── swift build -c release
  │     ├── creates .build/Blitz.app
  │     ├── copies dist/server/ → .build/Blitz.app/Contents/Resources/dist/server/
  │     ├── signs nested .node/.dylib
  │     └── signs .app with Developer ID
  ├── npm run build:pkg               # scripts/build-pkg.sh
  │     ├── copies .build/Blitz.app → build/pkg/payload/
  │     ├── re-signs app after copy
  │     ├── stages preinstall + postinstall scripts
  │     ├── pkgbuild (component .pkg)
  │     ├── productbuild (distribution .pkg)
  │     ├── productsign with Developer ID Installer
  │     └── notarizes + staples with xcrun notarytool
  └── npm run deploy                  # scripts/deploy-pkg.sh
        ├── validates CHANGELOG.md has v{version} section
        ├── checks version > latest in R2
        ├── uploads Blitz-{version}.pkg to R2
        ├── uploads Blitz-{version}.app.zip to R2
        ├── uploads release.json to R2
        └── updates latest.json in R2
```

**Snapshot (staging) deploy:**
```
npm run deploy:snapshot
```

**Local test (full install):**
```
npm run bundle:all
```

---

## Progress

- [x] `docs/cicd-migration.md` — this file
- [x] `package.json` — thin npm wrapper created
- [x] `CHANGELOG.md` — initial changelog created
- [x] `scripts/build-server.mjs` — sidecar bundler created
- [x] `scripts/build-pkg.sh` — PKG creator ported from blitz-cn
- [x] `scripts/deploy-pkg.sh` — R2 uploader ported from blitz-cn
- [x] `scripts/Entitlements.plist` — entitlements created
- [x] `scripts/pkg-scripts/preinstall` — preinstall ported (bundle ID updated)
- [x] `scripts/pkg-scripts/postinstall` — postinstall ported from blitz-cn
- [x] `scripts/bundle.sh` — updated with version injection + sidecar copy + deep signing
- [x] `Sources/BlitzApp/Services/NodeSidecarService.swift` — added `~/.blitz/node-runtime` to node search paths
