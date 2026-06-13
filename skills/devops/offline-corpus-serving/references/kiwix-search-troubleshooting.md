# Kiwix "search returns no result every time" — diagnosis transcript

**Symptom (user-reported):** Kiwix loads in the browser, but typing anything in the
search box returns "no result" every time. Desired end state: user searches Wikipedia
in the browser AND the agent can pull from it programmatically.

**System:** kiwix-tools 3.8.2, `ghcr.io/kiwix/kiwix-serve:latest`, single 49G ZIM
(`wikipedia_en_all_nopic_2026-03.zim`), served via `--library /data/library.xml`,
port 8181, on ChubeeAcer. User access is REMOTE via Tailscale IP (100.65.206.99) —
NOT localhost. (This matters: agent-side `localhost` test URLs are useless to the user.)

## What was actually true

The server was **100% healthy the entire time.** Fulltext search returned results
through every endpoint the browser uses — EXCEPT the one with an empty language filter:

| Query | Result |
|---|---|
| `/search?pattern=kansas` (bare) | `Results 1-25 of 204,068` OK |
| `/search?books.filter.lang=eng&pattern=kansas` | `204,068` OK |
| `/search?books.filter.category=wikipedia&pattern=kansas` | `204,068` OK |
| `/content/<zim>/Theodore_Roosevelt` (direct article) | full 900 KB article OK |
| `/search?books.filter.lang=&pattern=kansas` (EMPTY lang) | `Invalid request` FAIL |
| `/search?books.name=wikipedia_en_all&pattern=...` (legacy param) | `no-such-book` FAIL |

## ROOT CAUSE (confirmed, not guessed)

The stock Kiwix **welcome page** sends an **empty `books.filter.lang=`**. The landing
URL hash is `#lang=&q=kansas` — empty `lang`. The skin JS turns that into
`/search?books.filter.lang=&pattern=kansas`, and **kiwix-serve 3.8.2 rejects an empty
`books.filter.lang=` as "Invalid request,"** which the UI renders as "no result".

This was PROVEN, not assumed:
- User hard-refreshed -> still failed (so it is NOT browser cache).
- Direct content URL (`/content/<zim>/Theodore_Roosevelt`) loaded fine in the user's
  browser -> content serving works client-side.
- `/search?...lang=eng...` returned 204,068 results in the user's browser -> engine fine.
- Only the empty-`lang=` variant 400s.

The welcome page's search box is a BOOK-TILE filter with language auto-detect (skin
`index.js` ~line 677-684: reads `navigator.language`, sets the lang filter only if a
book exists in that language). On a single-English-book library, if the browser lang
isn't `en` or the URL carries an empty `lang=`, the filter goes empty and every landing
search 400s.

## THE FIX THAT WORKED: --customIndex

Serve a custom welcome page whose search form posts straight to the working endpoint
with a hardcoded `books.filter.lang=eng`, bypassing the broken auto-detect.

```yaml
# docker-compose.yml — kiwix service
command: ["--library", "/data/library.xml", "--customIndex", "/data/welcome.html"]
```

`welcome.html` (in `/mnt/chubee-data/corpora/` -> `/data/`), critical form:
```html
<form action="/search" method="get">
  <input type="hidden" name="books.filter.lang" value="eng">
  <input type="search" name="pattern" placeholder="Search Wikipedia">
  <button type="submit">Search</button>
</form>
```

### Two gotchas that bit during the real fix

1. **File perms — the container restart-loops.** `write_file` created `welcome.html`
   as `-rw-------` (owner-only, uid 1000). The kiwix container runs as **uid 1001** and
   couldn't read it -> log: `ERROR: No such file exist (or file is not readable)
   /data/welcome.html`, container restart-loops. **Fix: `chmod 644` the file after
   writing.** Always chmod 644 any host file the container must read.
2. **Place it in the mounted volume from the host** (uid 1000 owns `corpora/`), and
   reference by the in-container path `/data/welcome.html`.

### Verify end-to-end (use the USER's IP, not localhost)

```bash
curl -s 'http://<USER_IP>:8181/' | grep -o 'Chubee Offline Library'                       # custom page served
curl -s 'http://<USER_IP>:8181/search?books.filter.lang=eng&pattern=kansas' | grep Results # form target works
```
Tell the user to hard-refresh once to drop the cached old welcome page.

## The identifier mismatch (real, but a separate issue)

`library.xml` book `<name>` = `wikipedia_en_all`. Content path kiwix keys on =
`wikipedia_en_all_nopic_2026-03` (ZIM filename minus `.zim`). So `books.name=` queries
fail with `no-such-book`; `content=` and `books.filter.name=` succeed. For agent
access, use `content=<zim-filename-no-ext>`.

## Process lessons (two, both real)

1. **Don't lead with "stale browser cache."** An earlier version of this doc concluded
   the cause was browser cache. It was NOT — the user hard-refreshed and it still failed.
   The actual cause was the empty-lang query. Reproduce the EXACT failing request and
   bisect it (change one param at a time) before blaming the client.
2. **Don't mutate a working service while diagnosing.** In an earlier pass, the symptom
   was misdiagnosed as a library problem: backed up `library.xml` (good), then DELETED
   the live file (bad) to regenerate via `kiwix-manage` — which failed on the uid
   1001-vs-1000 write-permission boundary, leaving kiwix with no library for ~30s. Run
   read-only probes (`/search?content=...`, `/catalog/v2/entries`) FIRST; they prove the
   server is fine in seconds and redirect you to the real (client/UI) layer.
