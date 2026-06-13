# Deep Research Literature — Condensed Findings

## DEFT Failure Taxonomy (OPPO AI, Dec 2025)

Paper: "How Far Are We from Genuinely Useful Deep Research Agents?"
Source: arXiv 2512.01948

### Failure distribution across ~1,000 reports

| Category | Share | Key failure modes |
|----------|-------|-------------------|
| **Generation** | **39%** | Strategic content fabrication (unsupported but professional-sounding text), missing citations, superficial analysis |
| **Retrieval** | **32%** | Insufficient evidence integration, poor fact-checking, missing contradictory sources |
| **Reasoning** | **29%** | Logical gaps, refusal to concede uncertainty, weak planning |

### Core finding
Current DRAs struggle **not with task comprehension** but with evidence integration, verification, and reasoning-resilient planning. More search iterations amplify generation failures — the agent writes a longer version of the same wrong conclusion.

## Tongyi DeepResearch (Alibaba, May 2026)

Paper: arXiv 2510.24701

### Key architecture
- **30.5B total params, 3.3B activated per token** (Qwen3-30B-A3B-Base)
- End-to-end agentic training: mid-training → post-training (SFT + RL)
- Synthetic data pipeline (no human annotation)

### Three environment types for training
| Environment | Stability | Cost | Use case |
|-------------|-----------|------|----------|
| Prior World | Perfect | Zero | Large-scale initial bootstrapping |
| Simulated | High | Low | Strategy validation |
| Real-world | Dynamic | High | Final training |

### Benchmark scores
- HLE: 32.9, BrowseComp: 43.4, BrowseComp-ZH: 46.7
- WebWalkerQA: 72.2, GAIA: 70.9, FRAMES: 90.6

## LangChain Open Deep Research

### Architecture
- **Separate models per tier**: summarization (gpt-4.1-mini), research (gpt-4.1), compression (gpt-4.1), final report (gpt-4.1)
- Default search: Tavily (swap out via config)
- Full MCP support

### Design pattern
```
Loop: search → summarize → identify gaps → refine search → ...
Terminates when gaps are filled or iteration limit reached
```

## Tool Performance Comparison

| Tool | Time per query | Depth | Strengths |
|------|---------------|-------|-----------|
| OpenAI Deep Research | 5-30 min | Very deep | Multi-modal, code execution, transparent reasoning |
| Gemini Deep Research | <15 min | Moderate | 1M token context, Google search, user approves plan |
| Perplexity Deep Research | 2-4 min | Moderate | Fastest, most sources per query, inline citations |
| Grok DeepSearch | "Lightning-fast" | Concise | Real-time/X data, code interpreter |

## Three-Layer Architecture (Firecrawl)

| Layer | Job | Example |
|-------|-----|---------|
| **Retrieval** | Get raw web data | SearXNG, Tavily, browser, curl |
| **Orchestration** | Decide what/when to search | Agent loop, gap analysis logic |
| **Reasoning** | Turn results into answers | The LLM (current session model) |

Each layer has a clean boundary — swap retrieval without touching orchestration, or change models without rebuilding retrieval.

## Key Lessons

1. **39% of errors are generation-side** — citation discipline is the highest-leverage guardrail
2. **Diminishing returns on iteration** — beyond 2-3 passes, you're amplifying fabrication risk
3. **Tier models** — cheap summarizer + expensive reasoner beats one model doing everything
4. **Parallel extraction** — fetch URLs concurrently, synthesize sequentially
5. **Plan approval** — Google's approach of showing the plan first is good UX for human-in-the-loop
6. **Stopping conditions matter** — Jina's "until answer found or token budget hit" is the cleanest termination policy
7. **Synthetic data scales** — Tongyi proved you can train research agents without human annotation