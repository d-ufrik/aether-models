# Hosting — GGUF weights on Cloudflare R2

**Status (2026-06-12):** plan documented, not yet executed. The R2
bucket needs to be created + a custom domain bound. After that the
`upload-to-r2.sh` helper handles all subsequent uploads.

## Why R2 (and not GitHub LFS / Releases / Hugging Face direct)

| Option | Storage cost | Egress cost | Per-file limit | Catch |
|---|---|---|---|---|
| **Cloudflare R2** ✓ | $0.015/GB/mo | **free** | None | Custom domain via DNS + Workers |
| GitHub LFS | $5/mo per 50 GB | $5/mo per 50 GB | 5 GB | Bandwidth meter blows up under download spikes |
| GitHub Releases | free | free | 2 GB | Our Qwopus + Gemma already exceed this |
| Hugging Face direct | free | free | none | Catalog URLs lock us into HF's URL scheme + redirects |
| S3 + CloudFront | $0.023/GB/mo | $0.085/GB | None | Egress is the killer at scale |
| Backblaze B2 + bunny.net | $0.005/GB/mo | $0.01/GB | None | Cheapest cold storage, more vendors to babysit |

R2 + a Cloudflare custom domain gives us free egress at the
project's current scale (Aether is alpha; even 1 000 installs at
3 GB each = 3 TB transfer, which costs $0 on R2 vs $255 on S3 vs
GitHub LFS rate-limiting hell).

## Bucket layout

```
ufrik-aether-models                                 (R2 bucket name)
└── /
    ├── catalog.xml                                 (mirrored from this repo's main branch)
    ├── llamacpp/
    │   ├── qwopus-3.5-4b-coder-mtp-q4_k_m/
    │   │   └── model.gguf                          (2.78 GB)
    │   ├── gemma-4-e2b-it-q4_k_s/
    │   │   └── model.gguf                          (3.04 GB)
    │   └── ...
    └── manifests/
        └── <model-id>.json                         (per-model metadata mirrored from this repo)
```

The catalog references each weight as
`https://aether-models.ufrik.com/llamacpp/<id>/model.gguf`. The
custom domain `aether-models.ufrik.com` CNAMEs to the R2 public
endpoint (or routes through a Worker that adds caching headers).

## Active bucket (2026-06-12)

| Field | Value |
|---|---|
| Account ID | `32215393d4d7bd009bda52838cec119f` |
| Bucket name | `ufrik-aether-models` |
| S3-API endpoint | `https://32215393d4d7bd009bda52838cec119f.r2.cloudflarestorage.com` |
| Public download URL | (TBD — either bind `aether-models.ufrik.com` or enable the `pub-*.r2.dev` URL) |

## One-time setup (operator)

You only do this once, when bootstrapping the R2 bucket. After
that, `upload-to-r2.sh` handles every subsequent push.

**Tool of choice depends on file size:**

| File size | Tool | Why |
|---|---|---|
| ≤ 300 MiB | `wrangler r2 object put` | Cloudflare-native, single-shot, no chunking needed |
| > 300 MiB | `rclone copy` | Wrangler refuses files over 300 MiB. rclone does S3-multipart, handles 5 GB+ files, and is the tool Cloudflare's own R2 docs recommend for bulk transfers |

Both tools are non-AWS-branded and Cloudflare-supported. Do NOT
use `aws s3` — it works because R2 is S3-compatible, but it's the
wrong-vibe tool for a Cloudflare service and bundles a heavy CLI
we don't need.

**Auth (both tools):** the project keeps Cloudflare credentials in
the gitignored file
`<repo-root>/.cloudflare-r2` (sibling of this `aether-models/`
directory, NOT inside it — to avoid the file ever being mounted
into a build artifact). Format:

```
AccessKeyID=...           # for rclone / raw S3
SecretAccessKey=...       # for rclone / raw S3
Tokenvalue=cfut_...       # for wrangler (CLOUDFLARE_API_TOKEN)
endpoint=https://<account-id>.r2.cloudflarestorage.com
```

`.gitignore` excludes `.cloudflare*` in both the main repo and
this one, so rotating or accidentally copying the file in won't
publish it.

**rclone setup (one-time):** see step 6 below. After config the
upload script `upload-to-r2.sh` shells out to rclone for the
multipart push.

**wrangler setup (one-time, optional):** install via
`npm install -g wrangler` and either `wrangler login` (interactive
OAuth) or export `CLOUDFLARE_API_TOKEN=$(grep ^Tokenvalue= .cloudflare-r2 | cut -d= -f2)`
for non-interactive workflows. Step 4 below describes the
underlying S3-API credentials, useful if you need raw HTTP /
SigV4 (e.g. from a service that can't run wrangler or rclone).

1. **Sign in** at <https://dash.cloudflare.com> → your account →
   R2.
2. **Create a bucket** named exactly `ufrik-aether-models`. Region:
   automatic. (Already done on 2026-06-12.)
3. **Allow public access** on the bucket. Settings → Public Access
   → Allow Access → confirm. (Bucket policy stays read-only public;
   write requires the R2 API token below.)
4. **Generate an R2 API token** scoped to read+write on the
   `ufrik-aether-models` bucket. R2 → Manage API Tokens → Create
   API Token → permissions = "Object Read & Write", bucket =
   `ufrik-aether-models`. Save the resulting:

   ```
   Access Key ID:        ...
   Secret Access Key:    ...
   Endpoint URL:         https://32215393d4d7bd009bda52838cec119f.r2.cloudflarestorage.com
   ```

5. **Bind the custom domain** (optional but recommended).
   `aether.ufrik.com` is already a Cloudflare-managed zone, so:
   - DNS → CNAME `aether-models.ufrik.com` → `aether-models.<account-id>.r2.cloudflarestorage.com`
   - In R2 → bucket → Settings → Custom Domains → add
     `aether-models.ufrik.com`.
   - SSL is automatic.

6. **Configure rclone** (the right tool for multi-GB uploads):

   ```bash
   mkdir -p ~/.config/rclone
   cat > ~/.config/rclone/rclone.conf <<'EOF'
   [r2]
   type = s3
   provider = Cloudflare
   access_key_id = <AccessKeyID from .cloudflare-r2>
   secret_access_key = <SecretAccessKey from .cloudflare-r2>
   endpoint = https://32215393d4d7bd009bda52838cec119f.r2.cloudflarestorage.com
   region = auto
   acl = private
   EOF

   # Verify
   rclone lsd r2:
   # Expected: shows ufrik-aether-models (alongside any other buckets)
   ```

   Or set up `~/.aws/credentials` if you prefer (rclone reads
   either, but the dedicated `[r2]` remote keeps R2 isolated from
   any real AWS profiles).

7. **Optional — also export an env-style alias** for raw shell
   scripts that don't use rclone:

   ```bash
   export R2_BUCKET="ufrik-aether-models"
   export R2_PUBLIC_BASE="https://aether-models.ufrik.com"
   ```

   Store these in 1Password / your password manager. Do **not**
   commit them to this repo.

## Day-to-day — adding a model

```bash
# 0. Make sure rclone is configured (one-time, see step 6 below)

# 1. Download the GGUF from upstream (or build a custom quant)
curl -fL --progress-bar \
  -o /tmp/my-model.gguf \
  https://huggingface.co/.../my-model-Q4_K_M.gguf

# 2. Push it to R2 (the helper computes sha256, calls rclone for
#    multipart, emits a manifest, and prints a catalog snippet)
./upload-to-r2.sh \
  --file /tmp/my-model.gguf \
  --id   my-model-q4_k_m \
  --engine llamacpp

# 3. Append the printed <model> block to catalog.xml
# 4. Commit catalog.xml + manifests/<id>.json
git add catalog.xml manifests/my-model-q4_k_m.json
git commit -m "Add my-model-q4_k_m to catalog"
git push origin main
```

The companion fetches the updated catalog on the next launch
(cache TTL ~24 h).

### Bulk / large-file alternative

For files > 300 MiB (any realistic .gguf) the helper uses rclone
under the hood. To upload manually:

```bash
rclone copy --progress \
            --s3-chunk-size 100M \
            --s3-upload-concurrency 4 \
  /path/to/model.gguf \
  r2:ufrik-aether-models/llamacpp/<id>/

# Rename to canonical model.gguf (rclone preserves source name)
rclone moveto \
  r2:ufrik-aether-models/llamacpp/<id>/<source-name>.gguf \
  r2:ufrik-aether-models/llamacpp/<id>/model.gguf
```

`--s3-chunk-size 100M` keeps the multipart-part count low for
large files (R2 allows 10 000 parts max).

## Sanity-check after a push

```bash
# direct R2 URL
curl -sI "https://aether-models.ufrik.com/llamacpp/my-model-q4_k_m/model.gguf" \
    | head -5
# expected: HTTP/2 200 + content-length matches the original
```

## Future: signed download URLs

If we later need to gate downloads (license enforcement, private
beta), R2 supports presigned URLs identical to S3. The companion
would call `POST /api/catalog/sign?model=<id>` against
`aether.ufrik.com`, get back a 15-minute presigned URL, and
download with that. Out of scope until there's a reason.

## See also

- [`upload-to-r2.sh`](./upload-to-r2.sh)
- [`MANIFEST.md`](./MANIFEST.md)
- [Cloudflare R2 docs](https://developers.cloudflare.com/r2/)
- [wrangler R2 reference](https://developers.cloudflare.com/r2/api/wrangler/)
- [R2 S3-compatible API reference](https://developers.cloudflare.com/r2/api/s3/api/) (if you ever need raw HTTP / SigV4 from a service, e.g. an automated upload pipeline outside of wrangler)
