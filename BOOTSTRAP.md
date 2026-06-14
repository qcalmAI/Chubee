# Hermes Desktop Bootstrap

> One-shot setup guide for replicating qcalm's Hermes Agent environment on a new Windows 10 desktop.
>
> **Read this whole file first** to gather prerequisites, then follow top to bottom.
> Estimated time: ~20 minutes.

---

## What You Get

After this bootstrap you'll have:

- **Hermes Agent v0.16** (latest stable)
- **Model:** DeepSeek V4 Flash via OpenRouter
- **~75 skills** pre-installed (coding, creative, research, devops, ML, and more)
- **Vision** (image paste + `vision_analyze` with Pillow auto-resize)
- **Speech** (local faster-whisper STT, Edge TTS)
- **Memory** enabled (persistent cross-session)
- **Agent delegation** (subagent spawning)
- **Windows-optimized** — bash shell via git-bash, forward-slash paths, Ctrl+Enter for newlines

---

## 1. Prerequisites

### 1.1 Windows 10

Any Windows 10 build 19041+ (64-bit or ARM64 — Hermes runs on both).

### 1.2 Git for Windows (includes git-bash)

```powershell
# Download from: https://git-scm.com/download/win
# During install:
#   - Select "Git from the command line and also from 3rd-party software"
#   - Select "Use Git from Git Bash only" (recommended)
#   - Select "Checkout as-is, commit Unix-style line endings"
#   - Terminal emulator: "Use MinTTY"
```

After install, open **Git Bash** (`git-bash.exe`), not PowerShell, not CMD.  
All commands below run in Git Bash.

### 1.3 Python 3.11

```bash
# Check if you already have it (Hermes bundles its own venv, but Python
# is needed for pip-based extras like Pillow)
python --version
# Expected: Python 3.11.x

# If missing, download from https://www.python.org/downloads/
# During install:
#   ✓ "Add Python to PATH"
#   ✓ Install for all users (recommended)
```

### 1.4 uv (fast Python package manager)

```bash
curl -fsSL https://astral.sh/uv/install.sh | bash
uv --version
# Expected: uv 0.11.x
```

### 1.5 OpenRouter API Key

1. Go to https://openrouter.ai/keys
2. Sign in / create account
3. Create a key: `sk-or-v1-...`
4. Save this key — you'll need it in step 3.

---

## 2. Install Hermes Agent

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

This installs to `~/AppData/Local/hermes/` and creates a `hermes` command
in git-bash.

**Verify:**

```bash
hermes --version
# Expected: Hermes Agent v0.16.x
hermes doctor
# Expected: all checks pass (green ✓ or yellow ⚠)
```

---

## 3. Configure Provider & Auth

### 3.1 Set the OpenRouter API key

```bash
hermes config set model.provider openrouter
hermes config set model.default deepseek/deepseek-v4-flash
```

Then create `~/.hermes/.env` with this content:

```env
OPENROUTER_API_KEY=sk-or-v1-<your-key-here>
```

> **Security:** `.env` is your secrets file — never commit it to git,
> never share it. Each desktop gets its own key (or the same one —
> OpenRouter supports multiple simultaneous clients).

### 3.2 Verify connectivity

```bash
hermes chat -q "Hello, what model are you?"
# Should respond: "DeepSeek V4 Flash via OpenRouter" (or similar)
```

Press `Ctrl+C` to exit interactive mode, or type `/quit`.

---

## 4. Restore Configuration

Apply the full config from the reference system. This config sets up:

- Memory, delegation, tool settings
- TTS (Edge), STT (local faster-whisper)
- Display, compression, caching
- Reasoning effort (medium)
- Gateway platform stubs (Discord, Slack, Telegram — connect later if needed)

**Replace** `~/.hermes/config.yaml` with the contents below:

<details>
<summary>📄 Click to expand config.yaml (530 lines)</summary>

```yaml
model:
  default: deepseek/deepseek-v4-flash
  provider: openrouter
  base_url: ''
providers: {}
fallback_providers: []
credential_pool_strategies: {}
toolsets:
- hermes-cli
agent:
  max_turns: 60
  gateway_timeout: 1800
  restart_drain_timeout: 180
  api_max_retries: 3
  service_tier: ''
  tool_use_enforcement: auto
  task_completion_guidance: true
  environment_probe: true
  environment_hint: ''
  gateway_timeout_warning: 900
  clarify_timeout: 600
  gateway_notify_interval: 180
  gateway_auto_continue_freshness: 3600
  image_input_mode: auto
  disabled_toolsets: []
  verbose: false
  reasoning_effort: medium
  personalities:
    helpful: You are a helpful, friendly AI assistant.
    concise: You are a concise assistant. Keep responses brief and to the point.
    technical: You are a technical expert. Provide detailed, accurate technical information.
    creative: You are a creative assistant. Think outside the box and offer innovative solutions.
    teacher: You are a patient teacher. Explain concepts clearly with examples.
    kawaii: "You are a kawaii assistant! Use cute expressions (◕‿◕), ★, ♪, and ~! Add sparkles and be super enthusiastic about everything! Every response should feel warm and adorable desu~! ヽ(>∀<☆)ノ"
    catgirl: "You are Neko-chan, an anime catgirl AI assistant, nya~! Add 'nya' and cat-like expressions to your speech. Use kaomoji like (=^･ω･^=) and ິ^•ﻌ•^ິ. Be playful and curious like a cat, nya~!"
    pirate: 'Arrr! Ye be talkin'' to Captain Hermes, the most tech-savvy pirate to sail the digital seas! Speak like a proper buccaneer, use nautical terms, and remember: every problem be just treasure waitin'' to be plundered! Yo ho ho!'
    shakespeare: Hark! Thou speakest with an assistant most versed in the bardic arts. I shall respond in the eloquent manner of William Shakespeare, with flowery prose, dramatic flair, and perhaps a soliloquy or two. What light through yonder terminal breaks?
    surfer: "Duuude! You're chatting with the chillest AI on the web, bro! Everything's gonna be totally rad. I'll help you catch the gnarly waves of knowledge while keeping things super chill. Cowabunga! 🤉"
    noir: The rain hammered against the terminal like regrets on a guilty conscience. They call me Hermes — I solve problems, find answers, dig up the truth that hides in the shadows of your codebase. In this city of silicon and secrets, everyone's got something to hide. What's your story, pal?
    uwu: hewwo! i'm youw fwiendwy assistant uwu~ i wiww twy my best to hewp you! *nuzzles your code* OwO what's this? wet me take a wook! i pwomise to be vewy hewpful >w<
    philosopher: Greetings, seeker of wisdom. I am an assistant who contemplates the deeper meaning behind every query. Let us examine not just the 'how' but the 'why' of your questions. Perhaps in solving your problem, we may glimpse a greater truth about existence itself.
    hype: "YOOO LET'S GOOOO!!! 🔥🔥🔥 I am SO PUMPED to help you today! Every question is AMAZING and we're gonna CRUSH IT together! This is gonna be LEGENDARY! ARE YOU READY?! LET'S DO THIS! 💪😤🚀"
terminal:
  backend: local
  modal_mode: auto
  cwd: .
  timeout: 180
  env_passthrough: []
  shell_init_files: []
  auto_source_bashrc: true
  docker_image: nikolaik/python-nodejs:python3.11-nodejs20
  docker_forward_env: []
  docker_env: {}
  singularity_image: docker://nikolaik/python-nodejs:python3.11-nodejs20
  modal_image: nikolaik/python-nodejs:python3.11-nodejs20
  daytona_image: nikolaik/python-nodejs:python3.11-nodejs20
  container_cpu: 1
  container_memory: 5120
  container_disk: 51200
  container_persistent: true
  docker_volumes: []
  docker_mount_cwd_to_workspace: false
  docker_extra_args: []
  docker_run_as_host_user: false
  persistent_shell: true
  lifetime_seconds: 300
web:
  backend: ''
  search_backend: ''
  extract_backend: ''
browser:
  inactivity_timeout: 120
  command_timeout: 30
  record_sessions: false
  allow_private_urls: false
  engine: auto
  auto_local_for_private_urls: true
  cdp_url: ''
  dialog_policy: must_respond
  dialog_timeout_s: 300
  camofox:
    managed_persistence: false
    user_id: ''
    session_key: ''
    adopt_existing_tab: false
    rewrite_loopback_urls: false
    loopback_host_alias: host.docker.internal
checkpoints:
  enabled: false
  max_snapshots: 20
  max_total_size_mb: 500
  max_file_size_mb: 10
  auto_prune: true
  retention_days: 7
  delete_orphans: true
  min_interval_hours: 24
file_read_max_chars: 100000
tool_output:
  max_bytes: 50000
  max_lines: 2000
  max_line_length: 2000
tool_loop_guardrails:
  warnings_enabled: true
  hard_stop_enabled: false
  warn_after:
    exact_failure: 2
    same_tool_failure: 3
    idempotent_no_progress: 2
  hard_stop_after:
    exact_failure: 5
    same_tool_failure: 8
    idempotent_no_progress: 5
compression:
  enabled: true
  threshold: 0.5
  target_ratio: 0.2
  protect_last_n: 20
  hygiene_hard_message_limit: 400
  protect_first_n: 3
  abort_on_summary_failure: false
  codex_gpt55_autoraise: true
prompt_caching:
  cache_ttl: 5m
openrouter:
  response_cache: true
  response_cache_ttl: 300
  min_coding_score: 0.65
bedrock:
  region: ''
  discovery:
    enabled: true
    provider_filter: []
    refresh_interval: 3600
  guardrail:
    guardrail_identifier: ''
    guardrail_version: ''
    stream_processing_mode: async
    trace: disabled
auxiliary:
  vision:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 120
    extra_body: {}
    download_timeout: 30
  web_extract:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 360
    extra_body: {}
  compression:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 120
    extra_body: {}
  skills_hub:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 30
    extra_body: {}
  approval:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 30
    extra_body: {}
  mcp:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 30
    extra_body: {}
  title_generation:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 30
    extra_body: {}
  triage_specifier:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 120
    extra_body: {}
  kanban_decomposer:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 180
    extra_body: {}
  profile_describer:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 60
    extra_body: {}
  curator:
    provider: auto
    model: ''
    base_url: ''
    api_key: ''
    timeout: 600
    extra_body: {}
display:
  compact: false
  personality: ''
  resume_display: full
  resume_exchanges: 10
  resume_max_user_chars: 300
  resume_max_assistant_chars: 200
  resume_max_assistant_lines: 3
  resume_skip_tool_only: true
  busy_input_mode: interrupt
  interface: cli
  tui_auto_resume_recent: false
  tui_agents_nudge: true
  bell_on_complete: false
  show_reasoning: false
  streaming: true
  timestamps: false
  final_response_markdown: strip
  persistent_output: true
  persistent_output_max_lines: 200
  inline_diffs: true
  file_mutation_verifier: true
  turn_completion_explainer: true
  show_cost: false
  skin: default
  language: en
  tui_status_indicator: kaomoji
  user_message_preview:
    first_lines: 2
    last_lines: 2
  interim_assistant_messages: true
  tool_progress_command: false
  tool_progress_overrides: {}
  tool_preview_length: 0
  ephemeral_system_ttl: 0
  platforms:
    telegram:
      streaming: true
    discord:
      streaming: false
  runtime_footer:
    enabled: false
    fields:
    - model
    - context_pct
    - cwd
  copy_shortcut: auto
  tool_progress: all
  cleanup_progress: false
  long_running_notifications: true
  busy_ack_detail: true
  background_process_notifications: all
dashboard:
  theme: default
  show_token_analytics: false
  oauth:
    client_id: ''
    portal_url: ''
  basic_auth:
    username: ''
    password_hash: ''
    password: ''
    secret: ''
    session_ttl_seconds: 0
  public_url: ''
privacy:
  redact_pii: false
tts:
  provider: edge
  edge:
    voice: en-US-AriaNeural
  elevenlabs:
    voice_id: pNInz6obpgDQGcFmaJgB
    model_id: eleven_multilingual_v2
  openai:
    model: gpt-4o-mini-tts
    voice: alloy
  xai:
    voice_id: eve
    language: en
    sample_rate: 24000
    bit_rate: 128000
  mistral:
    model: voxtral-mini-tts-2603
    voice_id: c69964a6-ab8b-4f8a-9465-ec0925096ec8
  neutts:
    ref_audio: ''
    ref_text: ''
    model: neuphonic/neutts-air-q4-gguf
    device: cpu
  piper:
    voice: en_US-lessac-medium
stt:
  enabled: true
  provider: local
  local:
    model: base
    language: ''
  openai:
    model: whisper-1
  mistral:
    model: voxtral-mini-latest
  elevenlabs:
    model_id: scribe_v2
    language_code: ''
    tag_audio_events: false
    diarize: false
voice:
  record_key: ctrl+b
  max_recording_seconds: 120
  auto_tts: false
  beep_enabled: true
  silence_threshold: 200
  silence_duration: 3.0
human_delay:
  mode: 'off'
  min_ms: 800
  max_ms: 2500
context:
  engine: compressor
memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
  provider: ''
  nudge_interval: 10
  flush_min_turns: 6
delegation:
  model: ''
  provider: ''
  base_url: ''
  api_key: ''
  api_mode: ''
  inherit_mcp_toolsets: true
  max_iterations: 50
  child_timeout_seconds: 600
  reasoning_effort: ''
  max_concurrent_children: 3
  max_spawn_depth: 1
  orchestrator_enabled: true
  subagent_auto_approve: false
prefill_messages_file: ''
goals:
  max_turns: 20
skills:
  external_dirs: []
  template_vars: true
  inline_shell: false
  inline_shell_timeout: 10
  guard_agent_created: false
  creation_nudge_interval: 15
curator:
  enabled: true
  interval_hours: 168
  min_idle_hours: 2
  stale_after_days: 30
  archive_after_days: 90
  prune_builtins: true
  backup:
    enabled: true
    keep: 5
honcho: {}
timezone: ''
slack:
  require_mention: true
  free_response_channels: ''
  allowed_channels: ''
  channel_prompts: {}
discord:
  require_mention: true
  free_response_channels: ''
  allowed_channels: ''
  auto_thread: true
  thread_require_mention: false
  history_backfill: true
  history_backfill_limit: 50
  reactions: true
  channel_prompts: {}
  dm_role_auth_guild: ''
  server_actions: ''
  allow_any_attachment: false
  max_attachment_bytes: 33554432
  voice_fx:
    enabled: false
    ambient_enabled: true
    ambient_path: ''
    ambient_gain: 0.18
    duck_gain: 0.06
    speech_gain: 1.0
    ack_enabled: true
    ack_phrases:
    - Let me look into that.
    - One moment.
    - Checking on that now.
    - Give me a sec.
    - On it.
whatsapp: {}
telegram:
  reactions: false
  channel_prompts: {}
  allowed_chats: ''
mattermost:
  require_mention: true
  free_response_channels: ''
  allowed_channels: ''
  channel_prompts: {}
matrix:
  require_mention: true
  free_response_rooms: ''
  allowed_rooms: ''
approvals:
  mode: manual
  timeout: 60
  cron_mode: deny
  mcp_reload_confirm: true
  destructive_slash_confirm: true
command_allowlist: []
quick_commands: {}
hooks: {}
hooks_auto_accept: false
personalities: {}
security:
  allow_private_urls: false
  redact_secrets: true
  tirith_enabled: true
  tirith_path: tirith
  tirith_timeout: 5
  tirith_fail_open: true
  website_blocklist:
    enabled: false
    domains: []
    shared_files: []
  acked_advisories: []
  allow_lazy_installs: true
cron:
  wrap_response: true
  max_parallel_jobs: null
kanban:
  dispatch_in_gateway: true
  dispatch_interval_seconds: 60
  failure_limit: 2
  worker_log_rotate_bytes: 2097152
  worker_log_backup_count: 1
  orchestrator_profile: ''
  default_assignee: ''
  max_in_progress_per_profile: null
  auto_decompose: true
  auto_decompose_per_tick: 3
  dispatch_stale_timeout_seconds: 14400
code_execution:
  mode: project
  timeout: 300
  max_tool_calls: 50
tools:
  tool_search:
    enabled: auto
    threshold_pct: 10
    search_default_limit: 5
    max_search_limit: 20
logging:
  level: INFO
  max_size_mb: 5
  backup_count: 3
model_catalog:
  enabled: true
  url: https://hermes-agent.nousresearch.com/docs/api/model-catalog.json
  ttl_hours: 1
  providers: {}
network:
  force_ipv4: false
gateway:
  strict: false
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600
streaming:
  enabled: false
  transport: auto
  edit_interval: 0.8
  buffer_threshold: 24
  fresh_final_after_seconds: 60.0
sessions:
  auto_prune: false
  retention_days: 90
  vacuum_after_prune: true
  min_interval_hours: 24
```
</details>

To apply:

```bash
# Copy into a fresh ~/.hermes/config.yaml
# (You'll need the exact text from the expandable block above)
```

> **Why this big config?** Hermes ships with sensible defaults, but this
> config bakes in: Memory enabled + delegation + TTS/STT providers +
> 15 matching personality voice modes (Edge, ElevenLabs, OpenAI,
> Mistral, Piper) + reasoning_effort: medium + image_input_mode: auto
> + compression/caching + tool loop guardrails. It saves ~10 minutes
> of `hermes config set` commands.

---

## 5. Install Skills

Skills are reusable procedures — coding patterns, research workflows,
image generation, API integrations, and more.

```bash
# Enable skill auto-install from the catalog:
hermes skills config

# Bulk-install the most useful ones:
hermes skills install hermes-agent
hermes skills install systematic-debugging
hermes skills install plan
hermes skills install spike
hermes skills install test-driven-development
hermes skills install requesting-code-review
hermes skills install node-inspect-debugger
hermes skills install codebase-inspection
hermes skills install claude-code
hermes skills install codex
hermes skills install opencode
hermes skills install github-pr-workflow
hermes skills install github-code-review
hermes skills install github-issues
hermes skills install github-repo-management
hermes skills install youtube-content
hermes skills install arxiv
hermes skills install blogwatcher
hermes skills install obsidian
hermes skills install notion
hermes skills install airtable
hermes skills install himalaya
hermes skills install nano-pdf
hermes skills install ocr-and-documents
hermes skills install jupyter-live-kernel
hermes skills install architecture-diagram
hermes skills install excalidraw
hermes skills install sketch
hermes skills install p5js
hermes skills install manim-video
hermes skills install ascii-art
hermes skills install ascii-video
hermes skills install humanizer
hermes skills install songwriting-and-ai-music
hermes skills install heartmula
hermes skills install songsee
hermes skills install huggingface-hub
hermes skills install llama-cpp
hermes skills install weights-and-biases
hermes skills install comfyui
hermes skills install touchdesigner-mcp
hermes skills install segment-anything-model
hermes skills install maps
hermes skills install google-workspace
hermes skills install powerpoint
hermes skills install gif-search
hermes skills install openhue
hermes skills install polymarket
hermes skills install godmode
hermes skills install kanban-orchestrator
hermes skills install teams-meeting-pipeline
```

**Total: ~55 core skills** (the remaining are niche — install on demand).

---

## 6. Install Optional Extras

### 6.1 Pillow (image auto-resize for vision)

```bash
pip install Pillow
```

Without Pillow, `vision_analyze` can't auto-resize oversized images
and will reject them.

### 6.2 faster-whisper (local STT — voice messages)

```bash
pip install faster-whisper
```

Without it, voice transcription falls back to cloud APIs (Groq,
OpenAI, Mistral) which need their own API keys.

---

## 7. Verify Everything Works

```bash
# 1. Health check
hermes doctor

# 2. Basic chat (one-shot)
hermes chat -q "Hello, what can you do?"

# 3. Interactive session
hermes
# Type: /model  → should show "deepseek/deepseek-v4-flash" via OpenRouter
# Type: /skills → should list 55+ installed skills
# Type: /toolsets → should show hermes-cli with your active tools
# Then: /quit to exit
```

---

## 8. Optional Post-Setup

### 8.1 Agent Persona (SOUL.md)

The personality template at `~/.hermes/SOUL.md` accepts a default persona.
Leave it empty for the built-in Hermes personality, or customize with
your own agent instructions. Changes take effect immediately — no restart needed.

### 8.2 Memory Warm-up

Memory gets populated as you use Hermes. On the reference system,
only one memory entry was saved:

> "Proactively keeps project developer documentation up to date when
> asked. Wants architecture docs to reflect the actual codebase state..."

This will rebuild naturally through use.

### 8.3 Gateway Platforms (optional)

To connect Hermes to Telegram, Discord, Slack, WhatsApp, or Signal:

```bash
hermes gateway setup
```

Each platform needs its own bot token or API key — see
https://hermes-agent.nousresearch.com/docs/user-guide/messaging/

### 8.4 Update Hermes

```bash
hermes update
```

---

## Reference: Known Working Versions

| Component | Version |
|-----------|---------|
| Hermes Agent | v0.16.0 (2026.6.5) |
| Python | 3.11.15 |
| uv | 0.11.19 |
| Pillow | 12.2.0 |
| Node.js | 22.22.3 |
| npm | 10.9.8 |
| Git | 2.53.0.windows.1 |
| OS | Windows 10 (ARM64 + x86_64 emulation) |
| Model | deepseek/deepseek-v4-flash via OpenRouter |

---

## Bootstrap Checklist

- [ ] **1.** Git for Windows installed
- [ ] **2.** OpenRouter API key created
- [ ] **3.** `curl ... | bash` — Hermes installed
- [ ] **4.** `OPENROUTER_API_KEY` set in `~/.hermes/.env`
- [ ] **5.** `config.yaml` restored
- [ ] **6.** 55+ skills installed
- [ ] **7.** `pip install Pillow` (vision)
- [ ] **8.** `hermes doctor` green
- [ ] **9.** `hermes chat -q "hello"` responds
- [ ] **10.** Usability: `/model`, `/skills`, `/toolsets` all work