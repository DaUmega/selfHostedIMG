# selfHostedIMG

Offline image generation in one Docker box: `sd-server`
(stable-diffusion.cpp) + a minimal web UI + Tor + SSH. No Python, no accounts,
no cloud. The host runs nothing but the Docker engine.

Text→image and image→image (including multi-reference: combine N images into
one) are both supported through an OpenAI-compatible API.

## Quickstart

```bash
./manage.sh start
./manage.sh auth "ssh-ed25519 AAAA..."   # your public key
./manage.sh onion                        # prints the .onion address
ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p" ai@$(./manage.sh onion)
```

Inside, over ssh:

```bash
# download a model (as the ai user, straight into the persistent volume)
curl -L -o /models/flux2-klein-4b-fp8.gguf \
  https://huggingface.co/<org>/<repo>/resolve/main/<file>.gguf

# (re)start the server with it; extra flags pass straight to sd-server
load-model flux2-klein-4b-fp8.gguf --vae-tiling
```

Then: `http://localhost:8090` for the web UI (on by default; `FRONTEND=0 ./manage.sh start`
for API only), `http://localhost:7860` for the raw API.

The loaded model is recorded in `/id/sd-model.args` (persistent volume), so a
container restart brings the same model back up. No model ships with the image.

## Suggested models (8GB VRAM)

- **FLUX.2 Klein 4B** (FP8/NVFP4 GGUF), 4-step distilled, fast, Apache 2.0.
  The comfortable pick for 8GB cards.
- **Qwen-Image-2.1** (`qwen-image-2.1-UC-Q4_K_M.gguf`, ~4.6GB), best open
  text-rendering in images, strong at edits. Needs its companions
  (text encoder 9.4GB + VAE 676MB) - fetch all three on the host, then import:
  ```bash
  REPO=abenzerps/Qwen-Image-2.1-Uncensored-Quantized
  for f in qwen-image-2.1-UC-Q4_K_M.gguf vae/qwen_image_2.1_vae_bf16.safetensors text_encoders/qwen3vl_8b_int8_convrot.safetensors; do
    curl -L -o "$(basename "$f")" "https://huggingface.co/$REPO/resolve/main/$f"
  done
  ./manage.sh import qwen-image-2.1-UC-Q4_K_M.gguf qwen_image_2.1_vae_bf16.safetensors qwen3vl_8b_int8_convrot.safetensors
  ```
  then inside:
  ```bash
  load-model qwen-image-2.1-UC-Q4_K_M.gguf --llm /models/qwen3vl_8b_int8_convrot.safetensors --vae /models/qwen_image_2.1_vae_bf16.safetensors --vae-tiling --backend te=cpu
  ```
  Tip from the quant publisher: keep the diffusion model in VRAM and let the
  big text encoder spill to system RAM (it runs once per prompt).

## API

OpenAI-compatible, on `:7860` (also proxied through the UI on `:8090/v1/*`):

```bash
# text -> image
curl -s http://localhost:7860/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"a beaver building a dam","size":"1024x1024"}'

# image -> image (edit one, or pass several images to combine them)
curl -s http://localhost:7860/v1/images/edits \
  -F "image=@a.png" -F "image=@b.png" \
  -F "prompt=combine these into one scene" -F "size=1024x1024"
```

Extra sd-server parameters (steps, guidance, sampler...) can be embedded at
the end of the prompt inside `<sd_cpp_extra_args>...</sd_cpp_extra_args>` tags.

## Hardware backends

One Dockerfile, backend selected at build time (Alpine-based, universal):

| Backend | Base | For |
|---|---|---|
| `vulkan` | Alpine | AMD / Intel / NVIDIA via `/dev/dri` |
| `cuda` | Ubuntu + CUDA runtime | NVIDIA (fastest on NVIDIA) |
| `cpu` | Alpine | anything, slow |

`manage.sh` auto-detects the right backend when you build: NVIDIA runtime
present → `cuda`, `/dev/dri` present → `vulkan`, otherwise `cpu`. You never
have to think about it:

```bash
./manage.sh build     # picks cuda on an NVIDIA box automatically
```

The cuda backend needs the NVIDIA Container Toolkit on the host, otherwise
docker can't see the GPU at all:

```bash
paru -S nvidia-container-toolkit   # CachyOS/Arch (yay works too, if you have it)
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker info | grep -i nvidia       # should now list the nvidia runtime
```

Force a specific backend when the detector gets it wrong (or for someone
else's machine):

```bash
BACKEND=vulkan ./manage.sh build
BACKEND=cpu ./manage.sh rebuild
```

If the image on disk was built with a different backend than the one
currently selected, `start` tells you and suggests a rebuild. `GPU=0`
disables GPU passthrough entirely.

**Mac Studio (Apple Silicon):** Docker on macOS is a Linux VM with no GPU
passthrough, so the container can't touch the GPU there. Run `sd-server`
natively (Metal build) instead, the UI and the `/v1` API contract are
identical, so everything above still applies except the Docker part.

## VRAM notes (8GB cards)

- `sd-server` holds ~2GB more VRAM than one-shot CLI generation (caches).
- `--vae-tiling` trades a little speed for a lot of VRAM at high res.
- Reference images for edits/combining cost extra VRAM; stay at 1024px or
  below on 8GB, upscale after if needed.
- Distilled models (Klein 4B): keep guidance at 1.0 and steps at 4-8.
  Raising guidance on a distilled model fries the image instead of helping.

## Ports

- `7860` : sd-server API (OpenAI-compatible)
- `8090` : web UI (the LLM box uses 8080, so no conflict)
- SSH only via the Tor hidden service; the container publishes no inbound
  ports to the internet. Tor only makes outbound connections.

## Layout

```
Dockerfile      # alpine-based, BACKEND build arg (vulkan/cuda/cpu)
entrypoint.sh   # tor -> sshd -> restore last model -> optional UI -> supervise
load-model      # (re)start sd-server with a model from /models (runs inside)
manage.sh       # build/start/stop/.../auth/onion/share/doctor (host side)
serve.go        # static UI + /v1 reverse proxy (Go stdlib only)
index.html      # minimal UI: txt2img tab + img2img tab (multi-file)
sshd_config     # key-only, ai user only
```
