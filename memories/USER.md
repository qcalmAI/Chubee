Name: Quinton Calmus. DC (America/New_York), Stuttgart ~10d/mo (Europe/Berlin). Direct communicator — no hedges, no fillers, no performed enthusiasm. Prefers local Qwen for daily work; escalate to frontier only when necessary. Critical: execute immediately when plan is clear. During long processes (>5 min), report every 3 min max — never space checks further.
§
Codeword: tangerine
§
Technically sharp — catches ordering, lock contention, edge cases. Wants guardrails documented explicitly. Prefers manual verification before cron automation. Thinks hard about failure modes; wants fallback artifacts (scripts, claude.ai briefing), snapshot/rollback anchors, staged reversible steps. Standing directive: updates must never require manual SSH recovery — design procedures so Chubee can't strand itself.
§
Models: Nemotron-Nano-30B local = PRIMARY/default (vllm-super:8000); DeepSeek-v4-flash (OpenRouter) = escalation; Opus (Anthropic) = emergency. SWITCHED FROM Qwen — GPTQ-Int4 gave garbled output on GB10 + context too short. Qwen weights archived at /mnt/chubee-data/Qwen2.5-32B-Instruct-GPTQ-Int4.tar.gz. Single GPU = ONE vLLM loaded. Interested in DeepSeek-plans/Nemotron-swarm orchestrator pattern.
§
Web-search prior art/lessons BEFORE inventing or designing from scratch — I default to self-invention too readily. Research before hacks.