# Wyoming Voice Stack — Session Reference

Added 2026-06-05 to `~/chubee/stack/docker-compose.yml`.

## Services

| Service | Image | Port | Model | Status |
|---|---|---|---|---|
| Wyoming Whisper | `rhasspy/wyoming-whisper:latest` | 10300 | `base-int8`, CPU, int8 | healthy |
| OpenWakeWord | `rhasspy/wyoming-openwakeword:latest` | 10400 | built-in default wake words | healthy |
| Wyoming Piper | `rhasspy/wyoming-piper:latest` | 10500 | `en_US-lessac-medium` | healthy |

## Data Volumes

```
/mnt/chubee-data/docker-volumes/wyoming-whisper/      → /data
/mnt/chubee-data/docker-volumes/wyoming-openwakeword/ → /data
/mnt/chubee-data/docker-volumes/piper-tts/            → /data
```

## Key Lessons

1. **Kokoro Wyoming is amd64-only.** Both `ghcr.io/relvacode/kokoro-wyoming` and `ghcr.io/nordwestt/kokoro-wyoming` have no arm64 variant. Grace Blackwell GB10 is aarch64 — they cannot run. Piper TTS is the native alternative.

2. **Whisper arm64 has no CUDA CTranslate2.** The arm64 build exists and works, but `--device cuda --compute-type float16` causes `ValueError: This CTranslate2 package was not compiled with CUDA support`. Must use `--device cpu --compute-type int8` and drop the GPU deploy section.

3. **Wyoming healthcheck pattern** uses bash `/dev/tcp` since Wyoming protocol is pure TCP/WebSocket, not HTTP:
   ```yaml
   healthcheck:
     test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/localhost/PORT'"]
   ```

4. **Piper's first run** downloads the voice model from the internet — first `docker compose up` takes ~30-60s before the container goes healthy.
