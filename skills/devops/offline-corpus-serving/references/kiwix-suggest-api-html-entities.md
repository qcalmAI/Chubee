# Kiwix suggest API — HTML entity handling

The `/suggest?content=<zim>&term=<term>` API returns JSON with `value` and `label`
fields that contain **HTML-escaped entities**. This is the number one cause of
broken links and garbled text in custom Kiwix search UIs.

## The problem

```json
{
  "value": "Superman (Superman &amp; Lois)",
  "label": "&lt;b&gt;Superman&lt;/b&gt; (&lt;b&gt;Superman&lt;/b&gt; &amp;amp; Lois)",
  "kind": "path"
}
```

- `value` contains `&amp;`, `&lt;`, `&gt;`, `&apos;`, `&quot;`, `&#39;`
- `label` contains the same plus `<b>` tags to highlight matched portions

**If you use these raw values to build article URLs:**
- `encodeURIComponent("Superman (Superman &amp; Lois)")` → the URL path contains literal `%26amp%3B` (the browser sees `&amp;`, not `&`)
- Kiwix tries to resolve `/content/<zim>/Superman_(Superman_&amp;_Lois)` → 404

**If you insert the raw label into `innerHTML`:**
- The browser decodes `&lt;b&gt;` to visible text `<b>` — not a bold tag
- The user sees: `<b>Superman</b> (...)` — raw HTML tags as garbage text

## The fix

Decode HTML entities before using suggest API values:

```javascript
function decodeHtml(s) {
  const d = document.createElement("div");
  d.innerHTML = s;
  return d.textContent || d.innerText || "";
}

// Apply at the suggest-function level — fixes all callers
async function suggest(content, term, limit) {
  const r = await fetch(`/suggest?content=${content}&term=${encodeURIComponent(term)}`);
  return (await r.json())
    .filter(x => x.kind === "path")
    .slice(0, limit)
    .map(x => ({
      value: decodeHtml(x.value),   // for building URLs
      label: decodeHtml(x.label),   // for rendering (bold tags become real <b>)
      content
    }));
}

// Now articleUrl() gets clean values:
// decodeHtml("Superman (Superman &amp; Lois)") → "Superman (Superman & Lois)"
// encodeURIComponent("Superman (Superman & Lois)") → correct URL with %26 for &
```

## Verification

```bash
# Confirm the decoded URL resolves in Kiwix:
curl -sI 'http://localhost:8180/content/wikipedia_en_all_nopic_2026-03/Superman_%28Superman_%26_Lois%29'
# → HTTP/1.1 302 Found (Kiwix redirects to the ZIM's actual article path)

# Without decoding:
curl -sI 'http://localhost:8180/content/wikipedia_en_all_nopic_2026-03/Superman_%28Superman_%26amp%3B_Lois%29'
# → HTTP/1.1 404 Not Found
```

## Subtlety: all-caps article names

The suggest API may return `"value": "SUPERMAN"` (all caps) for a Wikipedia
article whose URL you'd expect to be `/content/.../Superman`. Wikipedia ZIMs
support first-letter-redirects: requesting `/content/.../Superman` works fine
(it resolves to the SUperMAN article via the ZIM's built-in redirect engine).

The `exact match` logic in the search UI should match case-insensitively and
use the **suggest API's value** (not `titleCase(term)`) for the URL to avoid
unnecessary redirects, but either path works because of the redirect mechanism.
