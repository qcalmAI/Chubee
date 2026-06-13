# Kiwix landing-page search returns "no result" — empty-language-filter bug

**Version:** kiwix-tools 3.8.2 (ghcr.io/kiwix/kiwix-serve:latest), single English
ZIM (`wikipedia_en_all_nopic_2026-03.zim`), accessed remotely over Tailscale.

## Symptom

User loads Kiwix in browser, content browses fine, but typing in the welcome-page
search box returns "no results" EVERY time. Persists after hard-refresh. URL looks
like `http://<host>:8181/#lang=&q=kansas&category=wikipedia` — note `lang=` is empty.

## Why the usual "stale browser cache" diagnosis is WRONG here

The skill's original advice ("server works → it's browser cache") was disproven this
session: hard-refresh did nothing, and a direct article fetch
(`/content/wikipedia_en_all_nopic_2026-03/Theodore_Roosevelt`) loaded the full 900KB
article in the same browser. Content serving worked end-to-end; only the landing
search box failed.

## Root cause (proven by curl matrix)

The welcome page's search box is a BOOK-TILE filter, not a fulltext search. The
kiwix skin `index.js` (~line 677-684) auto-detects `navigator.language`, and when it
can't map to a stocked language it leaves the language filter empty. That produces a
fulltext request with an EMPTY `books.filter.lang=`, which kiwix-serve 3.8.2 rejects.

Reproduction matrix (all via the user's real host):

| Query | Result |
|---|---|
| `/search?books.filter.lang=&pattern=kansas` | **Invalid request** (the bug) |
| `/search?books.filter.lang=&books.filter.category=wikipedia&pattern=kansas` | Invalid request |
| `/search?pattern=kansas` | Results 204,068 ✓ |
| `/search?books.filter.lang=eng&pattern=kansas` | Results 204,068 ✓ |
| `/search?books.filter.category=wikipedia&pattern=kansas` | Results 204,068 ✓ |
| `/search?books.filter.tag=wikipedia&pattern=kansas` | Results 204,068 ✓ |

So the ONLY trigger is the empty `books.filter.lang=`. Every other shape works.

## Article URL-path quirk (separate, useful)

Direct content fetch needs NO `/A/` namespace prefix on this ZIM. Requesting
`/content/<zim>/A/Theodore_Roosevelt` returns **302 → /content/<zim>/Theodore_Roosevelt`.
Use the bare path (or follow redirects with `curl -L`). The `suggest` endpoint
returns the correct `path` value to use:
```bash
curl -s 'http://localhost:8181/suggest?content=wikipedia_en_all_nopic_2026-03&term=Theodore+Roosevelt' \
  | grep -oE '"path" : "[^"]*"'
# -> "path" : "Theodore_Roosevelt"
curl -sL 'http://localhost:8181/content/wikipedia_en_all_nopic_2026-03/Theodore_Roosevelt'
```

## Two book identifiers (recap, still true)

- catalog `<name>` from library.xml: `wikipedia_en_all`
- content path (ZIM filename minus `.zim`): `wikipedia_en_all_nopic_2026-03`
- `books.name=wikipedia_en_all` → "no-such-book" (legacy/wrong param)
- `books.filter.name=wikipedia_en_all` → works
- `content=wikipedia_en_all_nopic_2026-03` → works (best for agent access)

## Process lesson reinforced

Same lesson as the library.xml incident: PROVE the server is broken before mutating
it. Here the welcome-page search "no result" looked like a server/library fault but
was a client-side UI query-construction bug. The first move on a reported Kiwix
search failure is the curl matrix above (read-only), not a config edit. The fix that
touches the server (`--customIndex`) is a last resort, done with a backup.
