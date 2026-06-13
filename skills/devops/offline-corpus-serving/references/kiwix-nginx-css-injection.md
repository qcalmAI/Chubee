# Kiwix dark theme via nginx reverse proxy

Kiwix-serve has **no** `--customCSS` flag. The search results and article pages
use a built-in light-themed HTML template that can't be changed server-side.

To apply a dark theme to every page (welcome, search, articles from any ZIM),
use nginx as a reverse proxy with `sub_filter` to inject a `<style>` block into
every HTML response.

## Architecture

```
Port 8181 (public) → nginx:alpine → sub_filter injects <style> → Kiwix on 8180 (internal)
```

## Full nginx config (comprehensive selectors)

Write this to the corpora data directory (so it mounts into the container):

```nginx
server {
    listen 8080;

    location / {
        proxy_pass http://kiwix:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        sub_filter '</head>' '<style>
  :root { color-scheme: dark; }
  html, body, .container, .content, #content, main, article, section, header, footer, nav, aside,
  .page, .document, .wrapper {
    background: #0f1115 !important; color: #e6e6e6 !important;
  }
  a { color: #4c8bf5 !important; }
  a:visited { color: #7b9fe8 !important; }
  input, select, textarea, button {
    background: #181b22 !important; color: #e6e6e6 !important; border-color: #2a2e37 !important;
  }
  table, thead, tbody, tfoot { background: #0f1115 !important; color: #e6e6e6 !important; }
  tr, td, th { background: #181b22 !important; color: #e6e6e6 !important; border-color: #2a2e37 !important; }
  h1, h2, h3, h4, h5, h6 { color: #e6e6e6 !important; }
  p, li, dt, dd, label, legend { color: #e6e6e6; }
  pre, code, kbd, samp {
    background: #181b22 !important; color: #b0b5be !important; border-color: #2a2e37 !important;
  }
  .book-icon { filter: invert(0.85); }
  .tag, .badge { background: #232834 !important; color: #8a8f98 !important; }
  .infobox, .navbox, .mbox, .ambox { background: #181b22 !important; color: #e6e6e6 !important; }
  .infobox-header, .navbox-title, .navbox-group, .navbox-list { background: #181b22 !important; color: #e6e6e6 !important; }
  .answer, .question, .post-text, .answercell { background: #181b22 !important; color: #e6e6e6 !important; }
  .mw-highlight, .highlight, .syntaxhighlighter { background: #181b22 !important; }
  .mw-highlight pre, .highlight pre { background: #181b22 !important; color: #b0b5be !important; }
  [style*="background:#e"] { background: inherit !important; }
  [style*="background:#f"] { background: inherit !important; }
  [style*="color:black"] { color: #e6e6e6 !important; }
</style></head>';
        sub_filter_once on;
        sub_filter_types text/html;
    }
}
```

**Key selectors beyond the basic version:**

| Selector | What it covers |
|---|---|
| `table, thead, tbody` | Table backgrounds |
| `pre, code, kbd, samp` | Inline and block code |
| `.infobox, .navbox, .mbox` | Wikipedia info/navboxes (light #eee → dark #181b22) |
| `.answer, .question, .post-text` | Stack Exchange content blocks |
| `.mw-highlight, .highlight` | Wikipedia code syntax highlighting |
| `[style*="background:#e"]` | Kill inline light-gray backgrounds |
| `[style*="background:#f"]` | Kill inline near-white backgrounds |
| `[style*="color:black"]` | Kill hardcoded black text |

Every CSS property needs `!important` to override Kiwix's hardcoded inline styles.

## Docker Compose changes

- Kiwix moves to an internal port (8180), no direct public access.
- nginx:alpine handles port 8181 with the config mounted read-only.
- nginx depends on Kiwix being healthy before starting.
- Both healthchecks must use `127.0.0.1` not `localhost` (see Alpine IPv6 quirk below).

```yaml
  kiwix:
    ports: [ "8180:8080" ]
    healthcheck:
      test: ["CMD-SHELL", "wget -q http://127.0.0.1:8080 -O /dev/null"]

  kiwix-nginx:
    image: nginx:alpine
    ports: [ "8181:8080" ]
    volumes:
      - /mnt/chubee-data/corpora/kiwix-nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      kiwix:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q http://127.0.0.1:8080 -O /dev/null"]
```

## Alpine `localhost` IPv6 quirk

Alpine's `wget` resolves `localhost` to `::1` (IPv6), but nginx and most
services listen on `0.0.0.0` (IPv4 only). This causes `wget -q http://localhost:8080`
to fail with "Connection refused" even when nginx is serving fine.

**Fix**: always use `http://127.0.0.1:<port>` in healthchecks on Alpine-based
containers (`nginx:alpine`, `kiwix-serve`, `filebrowser`, etc.).

## Deployment

1. Write the nginx config: `/mnt/chubee-data/corpora/kiwix-nginx.conf`
2. Update `docker-compose.yml` with the two-service config above
3. `docker compose up -d`
4. Verify: `curl -s http://localhost:8181/search?pattern=test | grep -c '0f1115'` → returns >0
5. Verify across ZIM types: check Wikipedia, iFixit, Stack Exchange, LibreTexts, Gutenberg, Wiktionary articles all have dark backgrounds

## Sub-filter is compiled in

The `ngx_http_sub_module` is included in the default nginx:alpine build.
No custom Dockerfile needed.
