---
name: deep-research
description: Multi-turn iterative web research — search, extract, analyze gaps, refine, synthesize. Uses web_search (SearXNG) + web_extract fallback chain. Designed around the 2-pass pattern informed by the DEFT failure taxonomy.
---

# Deep Research — Multi-Turn Iterative Web Research

## When to use

Complex questions that can't be answered in one search/extract cycle:
- Comparisons across multiple sources/perspectives
- Topics where initial results need verification or counter-evidence
- Questions the user frames as "research" or "deep dive"
- Any query where a single answer might miss important nuance

Do NOT use for simple factual queries (use `knowledge-query` or a single `web_search` call).

## Core pattern

```
search(query) → extract(urls) → analyze(gaps) → refine(query) → search again → extract → synthesize
```

Standard: **2 passes** (breadth then depth). More passes produce diminishing returns — the DEFT paper found ~39% of deep-research errors are **generation-side fabrication**, not retrieval gaps. More search iterations amplify the feedback loop; they don't fix synthesis quality.

## Step 0 — Offline wiki baseline (Kiwix)

Before hitting the live web, query the local Kiwix server for a stable, reliable baseline. Kiwix serves pre-indexed ZIM archives (Wikipedia, Wikibooks, devdocs, etc.). This information was very reliable at the time it was frozen into the ZIM, but **may be dated** — Kiwix is updated only when ZIMs are rebuilt.

```
curl -s "http://localhost:8181/search?q=<query>&limit=3&format=json"
```

Pick the most relevant result, then fetch full text:

```
curl -s "http://localhost:8181/<book>/<path>"
```

**How to use Kiwix results:**
- Treat them as the **factual backbone** — stable facts (geography, history, definitions, established science) are trustworthy.
- **Flag anything time-sensitive** (population figures, economic data, current events, recent legislation) as potentially stale. Cross-check against live web sources in the next steps.
- If Kiwix returns nothing for your topic (not every topic is in the ZIMs), move on — no penalty.

## Pass 1 — Breadth (live web)

1. **Search broadly**: `web_search(query)` — get 5-10 results with titles + descriptions
2. **Rank by relevance**: pick the top URLs based on title/description match to the goal
3. **Extract content**: for each URL, try in order:
   a. `web_extract(url)` — works if extract backend is Firecrawl/Tavily/Exa/Parallel. Returns full-page markdown.
   b. **Wikipedia API** — if the data lives on Wikipedia (structured tables: airport routes, demographics, sports rosters), use `action=parse&prop=text&format=json&section=N` instead of scraping. Bypasses Cloudflare/paywalls and returns clean HTML. See `references/wikipedia-api-extraction.md` for the full technique.
   c. `curl -sL url | sed 's/<[^>]*>//g'` — fallback for plain HTML/MD pages. Handle Cloudflare blocks (medium.com, etc.) by trying `browser_navigate` instead.
   d. `browser_navigate + browser_snapshot` — last resort for JS-heavy or Cloudflare'd pages. Use `.full=true` for complete content vs the compact default.
4. **Initial synthesis**: combine Kiwix baseline + live web extracts. Structured summary with explicit claims and source URLs. Note where Kiwix info appears stale and the web sources provide updates.

## Gap analysis (between passes)

This is the make-or-break step. It should ask:
- Is the Kiwix baseline still current? — the ZIM file may be months or years old. Does the live web confirm, update, or contradict what Kiwix said?
- What perspectives are missing? — which stakeholder/topic angle wasn't covered?
- **"What claims need counter-evidence?"** — did all sources agree? If they all cite the same primary source, that's not independent verification.
- **"What contradictions exist?"** — where did sources disagree? That's a signal for deeper investigation.
- **"Was the search itself biased?"** — did the initial keywords constrain the results too much?

Do NOT ask: "What more detail can I find on the same topic?" — that's depth-seeking on the same path, which is where diminishing returns hit hardest.

## Pass 2 — Depth & Critique

1. **Search on identified gaps**: formulate counterfactual queries — "X criticism of Y", "alternative views on Z", "evidence against A"
2. **Extract those results**
3. **Final synthesis**: combine both passes. Every factual claim must cite a source URL. If no source supports a claim, mark it explicitly as **unsupported** rather than fabricating.

## Citation discipline (critical)

The DEFT paper found **39% of failures are generation-side**: agents produce unsupported but professional-sounding text. Enforce:

> "Every factual statement must be followed by `[source: URL]`. If you cannot attach a source URL from your extracted materials, mark the claim as `[UNSUPPORTED — source not found in any extracted page]`."

This isn't just a nice-to-have — it's the single highest-leverage guardrail against the most common failure mode.

## Stopping condition

Skip Pass 2 when:
- The topic is narrow and one pass clearly saturated the sources (all top results point to the same few pages)
- The user asked a yes/no or definitional question (use `knowledge-query` or single search)
- Pass 1 already found conflicting information that would need human judgment to resolve (surface the conflict clearly instead of searching for a tiebreaker)

## When to escalate beyond 2 passes

Some questions genuinely need deep research (like OpenAI/Gemini's 80-150 search tasks for PhD-level questions). If the user explicitly asks for "deep research" or the topic is clearly cross-domain and complex, use this pattern instead:

```
loop {
  search(goal) → extract(results) → analyze(gaps) → refine(goal)
}
```

With these conditions:
- **Tier the models**: use a cheaper/faster model for summarization (~Nemotron for daily work) and the main model for analysis/planning. LangChain's Open Deep Research uses gpt-4.1-mini for summarization and gpt-4.1 for research.
- **Set a hard iteration limit** (max 4-5 passes) — beyond that, you're paying for diminishing returns.
- **Parallelize extracts** where possible — fetch multiple URLs simultaneously.

## Pitfalls

- **Kiwix data is reliable but possibly dated** — the ZIM archives are frozen snapshots. Stable facts (geography, history, science) are trustworthy. Time-sensitive data (population, politics, economics) needs cross-checking against live web sources. If Kiwix returns nothing for the query, skip it and proceed.
- **web_extract with SearXNG as extract backend will fail** — the error is `"SearXNG is a search-only backend and cannot extract URL content"`. Always have the fallback chain ready.
- **Structured data sites (FlightsFrom, FlightConnections, etc.) are often Cloudflare-protected or paywalled** — the browser will hit a Cloudflare challenge or a premium-only gate. Check if the same structured data exists on Wikipedia first (`action=parse` API). The Wikipedia API bypasses these protections entirely.
- **Medium.com and other JS-heavy sites block curl** — Cloudflare challenge page. Use `browser_navigate` for these.
- **Don't re-search the same query** — check if the refined query overlaps semantically with the first one. If it's essentially the same, you're in a loop.
- **Confirmation bias is automatic** — agents naturally find sources that support their initial framing. Counteract this in the gap analysis step explicitly.
- **web_search results are SearXNG** — no cloud API key needed (sovereign), but results quality depends on the configured search engines. If results are thin, try reformulating the query.
- **Length control** — extracts can be very long. Use `web_extract` (auto-summarizes pages >5000 chars) or truncate/select sections from browser snapshots.