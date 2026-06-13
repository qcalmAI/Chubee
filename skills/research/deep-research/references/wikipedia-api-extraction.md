# Wikipedia API for structured data extraction

When target sites are Cloudflare-protected or paywalled, Wikipedia's `action=parse` API is often a viable alternative for structured data (airport destinations, city demographics, company stats, species data, etc.).

## API pattern

```
curl -s 'https://en.wikipedia.org/w/api.php?action=parse&page=<Page_Name>&prop=text&format=json&section=<N>'
```

- `prop=text` returns parsed HTML of the section
- `section=N` returns only that section (much smaller payload than the full page)
- `prop=sections` (without `section=N`) lists all section indices and titles

## Finding the right section

```python
# List all sections
result = terminal("curl -s 'https://en.wikipedia.org/w/api.php?action=parse&page=<Page>&prop=sections&format=json'")
data = json.loads(result["output"])
for s in data["parse"]["sections"]:
    print(f"{s['index']}: {s['line']}")
```

## Parsing Wikipedia destination tables

Wikipedia's airline destination tables use a standard format: `<table>` with rows of `Airline | Destinations`. Key parsing challenges:

1. **Control characters** in JSON output — strip with `re.sub(r'[\x00-\x1f\x7f-\x9f]', '', raw)` before `json.loads()`
2. **"Seasonal: X, Y, Z"** prefix — applies to multiple comma-separated items. Normalize by inserting commas before bare "Seasonal" tokens: `re.sub(r'(?<!,)\s+(Seasonal)', r', \1', text)`
3. **Date annotations** — strip `(begins DD Month YYYY)` and `(resumes DD Month YYYY)` with `re.sub(r'\s*\(.*?\d{4}\)\s*', '', name)`
4. **Wikipedia reference brackets** — strip `[1][2]` style references with `re.sub(r'\[.*?\]', '', text)`
5. **Apostrophe normalization** — `O' Hare` vs `O'Hare`, `'` vs `'`
6. **Duplicate detection** — dedup close matches (e.g., `Zurich`/`Zürich`, `Male`/`Malé`) via a manual DEDUP map

## HTMLParser approach

Python's `html.parser.HTMLParser` is sufficient for Wikipedia's well-formed table markup. Track `in_table`, `in_tr`, `in_td`/`in_th` states. The destination column is typically column index 1 (second column after the airline name).

This approach avoids BeautifulSoup dependency and works entirely within `execute_code`'s Python stdlib.

## When to use this vs. alternatives

| Source | Use when |
|--------|---------|
| Wikipedia API | Structured data tables on Wikipedia pages — airport routes, city stats, species data, sports rosters |
| `web_extract` | Any plain-HTML page when Firecrawl/Tavily/Exa backend is configured |
| `curl` fallback | Plain-text endpoints (.md, .txt, .json, .yaml) or simple HTML |
| `browser_navigate` | JS-heavy or Cloudflare-protected pages (last resort, slow) |
