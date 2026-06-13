# ChubeeAcer Wyoming Voice Compose Configuration

Deployed on Acer Veriton GN100 (NVIDIA GB10 Grace Blackwell, arm64/aarch64).
Compose file: `~/chubee/stack/docker-compose.yml`

## Configured Services

### Wyoming Whisper (:10300)
- Model: base-int8
- Device: cpu (arm64 CTranslate2 lacks CUDA)
- Compute: int8
- Volume: /mnt/chubee-data/docker-volumes/wyoming-whisper:/data
- Image: rhasspy/wyoming-whisper (linux/arm64 native)

### Wyoming OpenWakeWord (:10400)
- Default wake words (bundled in image)
- Custom model dir available at /data for future custom .tflite models
- Volume: /mnt/chubee-data/docker-volumes/wyoming-openwakeword:/data
- Image: rhasspy/wyoming-openwakeword (linux/arm64 native)

### Wyoming Piper TTS (:10500)
- Voice: en_US-lessac-medium
- Volume: /mnt/chubee-data/docker-volumes/piper-tts:/data
- Image: rhasspy/wyoming-piper (linux/arm64 native)

## Previous Attempts
- Kokoro Wyoming (ghcr.io/relvacode/kokoro-wyoming): amd64 only, "exec format error" on arm64
- Kokoro Wyoming (ghcr.io/nordwestt/kokoro-wyoming): amd64 only, same error
- Piper was substituted as the Wyoming-native TTS backend for arm64

## Port Assignments
- Whisper STT: 10300
- OpenWakeWord: 10400
- Piper TTS: 10500
- (Convention: 103xx = STT, 104xx = wake word, 105xx = TTS)