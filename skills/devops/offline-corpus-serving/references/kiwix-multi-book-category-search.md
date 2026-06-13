# Kiwix Multi-Book Category Search Design

Deployed at `/mnt/chubee-data/corpora/welcome.html`. This documents the design
decisions and architecture that emerged from iterating through broken approaches
until the user demanded a clean ground-up design.

## Design Principles

1. **One search box** — typeahead while typing, full search on Enter/click
2. **Category pill buttons** — filter which ZIMs are searched
3. **Relevance-sorted results** — exact match first, then source-weighted
4. **Source attribution** — every result shows which ZIM/book it came from
5. **Links always work** — use `path` field from `/suggest`, not `value`
6. **Dark theme** — consistent #0f1115 / #e6e6e6 color scheme
7. **Fast typeahead** — samples one book from each category (Wikipedia + 1 from Forums, Textbooks, etc.) with 150ms debounce. Results are globally sorted by relevance score (not grouped by corpus)
8. **Fallback** — full-text `/search` link when title matches come up empty
9. **Vertical centering** — home page content is vertically centered via `justify-content: center` on body. When search results appear, a `.has-results` class switches to `flex-start` so results scroll from the top

## Architecture

```
Search box (top)
  ├── Typeahead dropdown (while typing)
  │     └── Samples one book from each category (9 total for "All")
  │           ├── Wikipedia + first book from Forums, Textbooks, Coding, Travel,
  │           │   Wiktionary, Medical, Repair, Literature
  │           ├── 6 results per book, fetched in parallel with Promise.allSettled
  │           ├── Merged, sorted by relevanceScore(value, term) across all sources
  │           │   (exact match=100, starts-with=80, contains=50)
  │           └── Each result shows source attribution on the right (faded text)
  └── Form submit (Enter / click Search)
        └── /suggest from ALL books in selected category (no filtering for "All")
              ├── Batched in chunks of 8 with Promise.allSettled
              ├── Merged, deduplicated by value.toLowerCase()
              ├── Scored: exact match +100, then source-weighted
              │     Wikipedia +50, Wiktionary +25, LibreTexts +30, etc.
              ├── Sorted by score desc, then alphabetically
              └── Rendered as numbered list with source tag badges
```

## Category Mapping

| Category | ZIMs searched | Count |
|---|---|---|
| All | All 76 registered ZIMs | 76 |
| Wikipedia | wikipedia_en_all_nopic | 1 |
| Forums | All Stack Exchange ZIMs | 29 |
| Textbooks | All LibreTexts ZIMs | 13 |
| API Docs | All DevDocs ZIMs | 28 |
| Travel | Wikivoyage | 1 |
| Wiktionary | Wiktionary | 1 |
| Medical | WikiMed (mdwiki) | 1 |
| Repair | iFixit | 1 |
| Literature | Gutenberg | 1 |

For "All", the full set of 76 ZIMs is filtered to ~30 major ones to keep search fast.
Single-category searches always search every book in that category.

## Scoring

Weights are in the `SCORE` object in welcome.html:

```javascript
const SCORE = {
  wp: 50, forums: 25, textbooks: 30, coding: 25,
  travel: 20, wiktionary: 25, medical: 20, repair: 20, lit: 20
};
const EXACT = 100;  // added when value.toLowerCase() === exact
```

Exact match detection uses `titleCase(term)` (capitalize first letter only) compared
case-insensitively against suggest `value` fields. This is deliberately minimal
(basically +100K) so it always sorts first.

## Getting Relevancy from Suggest (not Fulltext)

Kiwix `/search` uses Xapian term-frequency ranking — can't be changed server-side.
Pages that repeat the search term most outrank the actual article. The `/suggest`
endpoint matches article TITLES, which is genuine relevance for encyclopedia-style
searching. Results are ordered by the ZIM's title index (roughly alphabetical),
so the simplest/shortest article title usually floats to the top naturally.

The exact-match promotion ensures the main article (e.g. "Superman") is always
position 1 even when "Superman (1978)" comes first alphabetically.

## What Didn't Work (Iteration History)

1. **Redirect to article**: User hated it — wants search results, not blind redirect
2. **Typeahead-only Enter handling**: Race condition when typed fast (150ms debounce
   hadn't fired yet) — falls through to broken fulltext
3. **Single-book suggest**: Only searched the primary book, missing results from
   other ZIMs. User saw "where are the other categories?"
4. **Constructing URLs from `value`**: Worked for Wikipedia, 404 for iFixit, SE,
   LibreTexts. The `path` field is the fix — discovered when verifying
   `/content/ifixit_en_all_2025-12/Device/Chevrolet_Corvair` vs the broken
   `/content/ifixit_en_all_2025-12/Chevrolet_Corvair`
5. **HTML-escaped labels**: Suggest API returns `&lt;b&gt;` for bold, `&amp;` for `&`.
   Need `decodeHtml()` (create div, set innerHTML, read textContent) before display
   or URL construction
6. **Iterative patching**: Each fix introduced new friction. The clean ground-up
   rewrite was the right call once the design became clear
