# Filebrowser Password Reset

Filebrowser creates a random admin password on first run (printed to logs).
If lost, reset via a temp DB copy — the running process locks the live DB:

```bash
# 1. Copy the DB out of the container
docker cp filebrowser:/database/filebrowser.db /tmp/fb.db

# 2. Reset password on the copy (min 12 chars)
docker run --rm -v /tmp/fb.db:/fb.db filebrowser/filebrowser:latest \
  users update 1 --password "newpassword123456" --database /fb.db

# 3. Copy back and restart
docker cp /tmp/fb.db filebrowser:/database/filebrowser.db
docker restart filebrowser
```

Login: `admin` / `<new password>` at `http://<host>:8182`.
