# aether-models

Canonical catalog and manifest registry for Aether's downloadable
models. Hosted at <https://github.com/d-ufrik/aether-models>.

This repo holds **metadata**, not weights:

- `catalog.xml` — the live model catalog Aether.app fetches on
  every launch. URLs inside point at Cloudflare R2.
- `manifests/<model-id>.json` — per-model details (download URL,
  size, SHA-256, license, runtime hints).
- `prompts/` — Aether-specific prompt templates that ship inside
  the app catalog.
- `HOSTING.md` — how the GGUF binaries are hosted (Cloudflare R2
  + custom domain) and how to upload a new one.
- `upload-to-r2.sh` — operator helper script to push a new GGUF
  into the R2 bucket and update the catalog entry.

**The `.gguf` weight files themselves are NOT committed here.**
They live in a Cloudflare R2 bucket served at
`https://aether-models.ufrik.com/...` (or the bucket's
`r2.dev` URL until the custom domain is wired). See
[`HOSTING.md`](./HOSTING.md) for the full picture.

The `.gitignore` excludes `*.gguf` so a developer who pulls weights
locally for testing (the standard workflow) does not accidentally
commit a 3 GB binary to git.

---

## Local development cache

For development you'll have one or both GGUFs sitting next to this
README, downloaded directly from Hugging Face. That's intentional:
the `*.gguf` lines in `.gitignore` keep them out of git while
letting you point the standalone at local copies during iteration
on the wizard, installer, or routing layer. The current cached
files (when present):

| Model | File | Size | Source |
|---|---|---|---|
| Qwopus 3.5 4B Coder (MTP) | `Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf` | 2.78 GB | [Jackrong/Qwopus3.5-4B-Coder-MTP-GGUF](https://huggingface.co/Jackrong/Qwopus3.5-4B-Coder-MTP-GGUF) |
| Gemma 4 E2B Instruct | `gemma-4-E2B-it-Q4_K_S.gguf` | 3.04 GB | [unsloth/gemma-4-E2B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) |

To re-download:

```bash
curl -fL --progress-bar \
  -o Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf \
  https://huggingface.co/Jackrong/Qwopus3.5-4B-Coder-MTP-GGUF/resolve/main/Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf

curl -fL --progress-bar \
  -o gemma-4-E2B-it-Q4_K_S.gguf \
  https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_S.gguf
```

**Recorded SHA-256** (so you can verify a local copy or compare
against the manifest):

```
50b426c393fc07aba6438d8f7d66bad156e06a6afb6bb80f15def9c313efa133  Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf
0a2fac16f388b4839f075dedb681357aec3e73a96bd66b413e462b6853550c99  gemma-4-E2B-it-Q4_K_S.gguf
```

---

## Why this repo exists

Aether.app does not ship GGUF weights. The DMG is ~21 MB (proxy +
companion + tier'd llama-server binaries only). When a user
finishes onboarding and picks "Install a local model", the
companion reads `catalog.xml` from this repo (or the cache thereof)
to learn:

- Which models are available
- Their friendly names and use-case taglines
- The download URL (Cloudflare R2)
- The expected size + SHA-256
- License, runtime hints (MTP support, context default, GPU layer
  recommendation)

So:

- **Add a model** → upload its `.gguf` to R2 via
  `upload-to-r2.sh`, drop a `manifests/<id>.json`, append a
  `<model>` block to `catalog.xml`, commit + push.
- **Update a model** → same flow, optionally bump the catalog
  schema version.
- **Remove a model** → delete from R2, delete the manifest,
  remove from `catalog.xml`.

The companion's `ModelInstaller.swift` consumes the catalog at
runtime, downloads from R2, verifies SHA-256, and registers the
model with the local Aether proxy.

---

## Operational notes

- The live catalog URL Aether.app fetches is
  `https://aether.ufrik.com/models/catalog.xml`. That URL serves
  the same content as `catalog.xml` in this repo's `main` branch
  (mirrored / proxied by Cloudflare; setup in `HOSTING.md`).
- The companion ships a **fallback** catalog
  (`packaging/macos/catalog/catalog.sample.xml`) built into the
  bundle, used only when the network + on-disk cache both miss. Keep
  it in sync with `catalog.xml` here — both files should evolve
  together.
- The companion downloads GGUFs to
  `~/Library/Application Support/Aether/models/<engine>/<model-id>/model.gguf`.
  An MTP-enabled model also gets a `drafter.gguf` alongside.

---

## See also

- [`HOSTING.md`](./HOSTING.md) — Cloudflare R2 setup, custom
  domain, IAM token scopes
- [`MANIFEST.md`](./MANIFEST.md) — schema for `manifests/<id>.json`
- `packaging/macos/companion/Sources/AetherCompanion/ModelInstaller.swift`
  — the consumer side, in the main rust-local-ai-proxy repo
- `packaging/macos/catalog/catalog.sample.xml` — the bundled
  fallback catalog
- `packaging/macos/BUILD.md` — how Aether.app itself is built
