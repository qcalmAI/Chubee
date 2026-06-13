# Kiwix Library XML Workaround — Debug Chain

When `kiwix-serve` rejects a valid, complete ZIM file with "Unable to add the ZIM file to the internal library", use the library XML approach.

## Symptoms

```
docker logs kiwix
/usr/local/bin/kiwix-serve --port=8080 /data/wikipedia_en_all_nopic_2026-03.zim
Unable to add the ZIM file '/data/wikipedia_en_all_nopic_2026-03.zim' to the internal library.
Here is the content of /data:
/data/wikipedia_en_all_nopic_2026-03.zim
```

Server still starts and serves HTTP 200 on the welcome page, but the ZIM content is not accessible. Healthcheck may show `(unhealthy)` because `wget` gets the welcome page but `kiwix-serve` internally knows the library is empty.

## Root Cause

The direct ZIM path loading mechanism in some kiwix-serve versions (documented on kiwix-tools 3.8.2 with libzim 9.5.0) is fragile. The ZIM file itself is valid — confirmed by:

```
xxd -l 4 /path/to/file.zim
# Should show: 5a49 4d04 = "ZIM\x04" (valid ZIM magic bytes)
```

The file can also be confirmed as complete by comparing size vs expected or via `kiwix-manage` which successfully reads metadata once registered.

## The Fix

### Step 1 — Create library.xml from the host side

The container runs as uid 1001 (user), which can't write to `/` inside the container. Create the library file from the host:

```bash
cat > /mnt/chubee-data/corpora/library.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<library version="20110515">
</library>
EOF
chmod 666 /mnt/chubee-data/corpora/library.xml
```

### Step 2 — Register the ZIM using kiwix-manage inside the container

```bash
docker exec kiwix sh -c 'kiwix-manage /data/library.xml add /data/wikipedia_en_all_nopic_2026-03.zim'
```

Expected output: nothing (exit 0). No error message means success.

### Step 3 — Verify registration

```bash
docker exec kiwix sh -c 'kiwix-manage /data/library.xml show'
```

Expected output includes: `id`, `path`, `title`, `articleCount`, `size`. For the English Wikipedia nopic 2026-03: ~19M articles, ~48 GB.

### Step 4 — Update compose command and recreate

Change the command in compose from:

```yaml
command: ["/data/wikipedia_en_all_nopic_2026-03.zim"]
```

To:

```yaml
command: ["--library", "/data/library.xml"]
```

Then recreate:

```bash
docker compose -f ~/chubee/stack/docker-compose.yml up -d kiwix
```

### Step 5 — Confirm success

```bash
docker logs kiwix 2>&1 | tail -5
```

Should show:

```
The library was successfully loaded.
The Kiwix server is running and can be accessed in the local network at:
  - http://172.18.0.x:8080
  - http://[::1]:8080
```

And `docker ps` should show `(healthy)`.

## One-Time vs Persistent

The `library.xml` file and its contents persist in the mounted volume. After the initial `kiwix-manage add`, the library file is self-contained and survives container recreation, restarts, and updates. You only need to re-register ZIMs if you delete the `library.xml` or add new ZIM files.

## Adding More ZIMs Later

```bash
docker exec kiwix sh -c 'kiwix-manage /data/library.xml add /data/new_file.zim'
docker compose -f ~/chubee/stack/docker-compose.yml restart kiwix
```