---
name: wyoming-voice-pipeline
description: "Deploy Wyoming-compatible voice services (Whisper STT, OpenWakeWord, Piper TTS) via Docker on arm64 or amd64 systems."
version: 1.0.0
author: Chubee
license: MIT
metadata:
  hermes:
    tags: [voice, stt, tts, wyoming, docker, compose, arm64, piper, whisper, openwakeword]
    related_skills: []
---

# Wyoming Voice Pipeline

Deploy speech-to-text and text-to-speech infrastructure using the Wyoming protocol — Whisper (STT), OpenWakeWord (wake word detection), and Piper (TTS) — via Docker Compose. Intended for local/offline voice pipelines connected to Home Assistant or similar.

## When to Use

- Setting up voice infrastructure (STT, wake word, TTS) on a local network
- Adding Wyoming-compatible services to a Docker Compose stack
- Deploying on arm64 (e.g., NVIDIA GB10 Grace Blackwell, Raspberry Pi) where amd64-only images won't run
- Wiring a voice pipeline that Home Assistant's Wyoming integration can discover

## Architecture Compatibility

**Critical first step:** Check image platform before deploying on arm64 hosts.

```bash
docker inspect <image>:<tag> --format '{{.Os}}/{{.Architecture}}'
```

| Service | Image | arm64 | Notes |
|---|---|---|---|
| Whisper STT | `rhasspy/wyoming-whisper` | ✅ native | CTranslate2 lacks CUDA on arm64 → CPU only |
| OpenWakeWord | `rhasspy/wyoming-openwakeword` | ✅ native | Works fine with defaults |
| Piper TTS | `rhasspy/wyoming-piper` | ✅ native | Works fine, download voice model on first run |
| Kokoro TTS | `ghcr.io/relvacode/kokoro-wyoming` | ❌ amd64 only | No arm64 build available |
| Kokoro TTS | `ghcr.io/nordwestt/kokoro-wyoming` | ❌ amd64 only | No arm64 build available |

Kokoro Wyoming has no arm64 variant. Use Piper TTS as the Wyoming-native alternative on arm64.

## Docker Compose Configurations

### Wyoming Whisper (STT) — Port 10300

```yaml
  wyoming-whisper:
    image: rhasspy/wyoming-whisper:latest
    container_name: wyoming-whisper
    restart: unless-stopped
    ports:
    - 10300:10300
    volumes:
    - /mnt/chubee-data/docker-volumes/wyoming-whisper:/data
    command: --model base-int8 --uri tcp://0.0.0.0:10300 --data-dir /data --device cpu --compute-type int8
    healthcheck:
      test: ["CMD-SHELL", "wget -q http://localhost:10300 -O /dev/null"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s
```

**Key points:**
- `--model base-int8`: Good quality/speed balance. Other options: `tiny-int8` (fastest), `small-int8`, `medium`, `large-v3`.
- `--device cpu --compute-type int8`: **Required on arm64.** The arm64 image's CTranslate2 was not compiled with CUDA. Adding `--device cuda --compute-type float16` will crash with `ValueError: This CTranslate2 package was not compiled with CUDA support`.
- On amd64 with NVIDIA GPU, use `--device cuda --compute-type float16` and add the GPU `deploy.resources` block.
- Model downloads on first run to `/data`. Subsequent starts reuse the cached model.
- Healthcheck uses `wget` — the images are Alpine-based and lack `bash` and `curl`.

### Wyoming OpenWakeWord — Port 10400

```yaml
  wyoming-openwakeword:
    image: rhasspy/wyoming-openwakeword:latest
    container_name: wyoming-openwakeword
    restart: unless-stopped
    ports:
    - 10400:10400
    volumes:
    - /mnt/chubee-data/docker-volumes/wyoming-openwakeword:/data
    command: --uri tcp://0.0.0.0:10400
    healthcheck:
      test: ["CMD-SHELL", "wget -q http://localhost:10400 -O /dev/null"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
```

**Key points:**
- Default wake words (`okay_nabu`, `hey_jarvis`, `alexa`, etc.) are bundled in the image — no model config needed.
- `--threshold 0.5` controls sensitivity (lower = more sensitive, more false positives).
- `--custom-model-dir /data` — mount a volume and place custom `.tflite` wake word models here.
- Works fine on arm64 with default args.

### Wyoming Piper (TTS) — Port 10500

```yaml
  wyoming-piper:
    image: rhasspy/wyoming-piper:latest
    container_name: wyoming-piper
    restart: unless-stopped
    ports:
    - 10500:10500
    volumes:
    - /mnt/chubee-data/docker-volumes/piper-tts:/data
    command: --voice en_US-lessac-medium --uri tcp://0.0.0.0:10500 --data-dir /data
    healthcheck:
      test: ["CMD-SHELL", "wget -q http://localhost:10500 -O /dev/null"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s
```

**Key points:**
- `--voice en_US-lessac-medium` — good default English voice. Alternatives: `en_US-amy-medium`, `en_GB-vctk-medium`, `en_US-ryan-medium`.
- Voice model downloads on first run to `/data`. 60s start period to account for download time.
- `--update-voices` flag re-downloads the voice list on startup.
- `--use-cuda` for GPU acceleration on amd64 with NVIDIA GPU (not available on arm64).

## Common Pitfalls

1. **Missing `bash`/`curl` in healthchecks.** All Rhasspy Wyoming images are Alpine-based. They have `wget` but no `bash` or `curl`. Use `CMD-SHELL` with `wget -q` instead of `/dev/tcp` tricks or `curl`.
2. **Whisper CUDA crash on arm64.** The arm64 build of CTranslate2 lacks CUDA. Adding `--device cuda` causes a crash loop. Use `--device cpu --compute-type int8` on arm64.
3. **Port conflicts.** Default Wyoming ports: Whisper 10300, OpenWakeWord 10400, Piper 10500. Verify they're free before adding to compose.
4. **First-run model download.** Whisper downloads the model on first start. Piper downloads the voice model. Both need internet on first run. The healthcheck `start_period` must account for this.
5. **Home Assistant not ready.** These services will auto-discover via zeroconf/mDNS when Home Assistant's Wyoming integration is configured. Without HA, the services still run independently.

## Verification Checklist

- [ ] `docker compose ps` shows all services as "(healthy)"
- [ ] Ports respond: `nc -zv localhost 10300 && nc -zv localhost 10400 && nc -zv localhost 10500`
- [ ] Docker logs show no crash loops: `docker logs wyoming-whisper | grep -i error`
- [ ] Compose file persists at intended path (not ephemeral)
- [ ] Volumes mounted under persistent data directory
- [ ] Healthchecks use `wget` not `curl`/`bash`