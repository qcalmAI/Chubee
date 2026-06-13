# Adding more wikis + the multi-wiki picker welcome page

The custom welcome page (`/mnt/chubee-data/corpora/welcome.html`, served via
`--customIndex /data/welcome.html`) auto-discovers every ZIM in the library and
builds a picker. Adding a new wiki needs NO page edits.

## Picker label format & grouping (current design)

- Label format is **`<Description> (<Source>)`** for every wiki EXCEPT real
  Wikipedia, which is special-cased to **`Wikipedia (Classic)`** and pinned first.
  Examples: `Travel (Wikivoyage)`, `Dictionary (Wiktionary)`, `Medical (WikiMed)`,
  `Repair (iFixit)`, `Textbooks (Wikibooks)`.
- Order: Wikipedia (Classic) → All Wikis — Combined Search → each wiki alpha →
  grouped families last.
- **DevDocs are GROUPED into ONE entry** `API Docs (DevDocs)` instead of 28 separate
  options. Detection: the ZIM `<tags>` contains `devdocs`. Selecting the group does
  title-suggestion across all devdocs books (see ftindex note below).

## DevDocs gotcha: NO fulltext index

DevDocs ZIMs ship with **`_ftindex:no`** in their tags — `/search` does NOT work on
them, only `/suggest` (title index) and direct `/content/<zim>/<Article>`. This is
fine for API docs (you look up a symbol by name). The picker detects ftindex from
tags (`!/_ftindex:no/i`) and only offers a full-text option for books that have it.
DevDocs are tiny (~1-30 MB each; ~92 MB for 28 tools) and there is NO bundled "all
devdocs" ZIM — each tool is a separate file under `/zim/devdocs/`.

## Add a new wiki (3 steps)

```bash
# 1. Download the ZIM into the corpora dir (host side, uid 1000 owns it)
cd /mnt/chubee-data/corpora
wget -c --progress=dot:giga \
  "https://download.kiwix.org/zim/<project>/<file>.zim"
# verify magic bytes:
python3 -c "print(open('<file>.zim','rb').read(4))"   # must be b'ZIM\x04'

# 2. Register in the library. library.xml is owned by uid 1000 but kiwix-manage
#    runs in-container as uid 1001 and CANNOT write it by default -> "Cannot
#    write the library". Make it writable first:
chmod 666 /mnt/chubee-data/corpora/library.xml
docker exec kiwix kiwix-manage /data/library.xml add /data/<file>.zim

# 3. Restart kiwix (it caches both the library AND the --customIndex page at
#    startup; a file save alone is NOT picked up).
cd ~/chubee/stack && docker compose restart kiwix
```

The new wiki appears in the picker automatically, with a friendly description
mapped from its ZIM name (see DESCRIPTIONS table in welcome.html — extend it for
new projects).

## The picker (how welcome.html works)

- On load, fetches `/catalog/v2/entries`, parses each `<entry>` for `name`,
  `title`, content path (`href="/content/..."`), and `language`.
- Dropdown options, in order: **Wikipedia (Standard)** (default) → **All Wikis —
  Combined Search** → every other wiki as `Title (Description)`.
- Typeahead: exact-article jump first (`/content/<contentpath>/<Title>`, first
  letter capitalized — ZIM redirects resolve case/spacing), then `/suggest` title
  matches, then a full-text fallback.

## CRITICAL kiwix 3.8.2 search param gotchas (verified by testing)

Per-book fulltext scoping — **use `books.filter.name=`, NOT `books.name=`**:

| Param | Result |
|---|---|
| `/search?books.filter.name=wikivoyage_en_all&pattern=paris` | works (1,412) |
| `/search?books.filter.lang=eng&pattern=paris` | works (single English lib) |
| `/search?pattern=paris` (no filter) | works — searches ALL books (combined) |
| `/search?books.name=wikivoyage_en_all&pattern=paris` | **"Invalid request"** — legacy/wrong param |
| `/search?books.filter.lang=&pattern=paris` (EMPTY lang) | **"Invalid request"** — the welcome-page bug |

So in the picker:
- **A specific wiki** → scope with `books.filter.name=<library name>` (the `<name>`
  from library.xml, e.g. `wikivoyage_en_all` — NOT the content path with the date).
- **All Wikis** → submit bare `?pattern=` (no book/lang filter). Searches everything.
- Never emit `books.name=` or an empty `books.filter.lang=`.

## File perms + restart (both WILL bite)

- `write_file`/editors create files as `-rw-------` (owner-only, uid 1000). The
  kiwix container (uid 1001) can't read them → restart loop or 404. **`chmod 644`
  welcome.html after every write.**
- `--customIndex` is **cached at container startup**, not read per request. Any
  edit to welcome.html requires `docker compose restart kiwix` to take effect.
- After restart, tell the user to hard-refresh (`Ctrl/Cmd+Shift+R`) to drop the
  browser-cached old page.

## Two ZIM identifiers — don't confuse them

- **library `<name>`** (e.g. `wikivoyage_en_all`) — use for `books.filter.name=`.
- **content path** (e.g. `wikivoyage_en_all_maxi_2026-03`, the ZIM filename minus
  `.zim`) — use for `/content/<path>/Article` and `/suggest?content=<path>`.
Get both from `/catalog/v2/entries`.
