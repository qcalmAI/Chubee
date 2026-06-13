#!/usr/bin/env python3
"""
Spotify manual-paste OAuth for Dockerized Hermes.

No SSH tunnel, no Tailscale IP, no patching needed. Instead:
1. Generates PKCE params and writes the auth URL to /tmp/spotify_auth_url.txt
2. Waits for the user to paste the failed redirect URL into /tmp/spotify_callback.txt
3. Reads the file, exchanges the code, writes tokens to auth.json

Usage:
  1. Update CLIENT_ID below
  2. docker cp spotify_manual_paste.py hermes:/tmp/
  3. docker exec hermes python3 /tmp/spotify_manual_paste.py &
  4. docker exec hermes cat /tmp/spotify_auth_url.txt  → give URL to user
  5. User opens URL, approves, gets failed redirect — copies the URL
  6. docker exec hermes sh -c 'cat > /tmp/spotify_callback.txt'
     (paste the URL, Ctrl+D)
  7. Script exchanges code, writes to auth.json
  8. docker exec hermes hermes auth status spotify
"""
import hashlib, base64, json, os, random, string, time
from urllib.parse import urlencode, parse_qs
from datetime import datetime, timezone, timedelta
import httpx

# ─── CONFIGURE ─────────────────────────────────────────────────────────────
CLIENT_ID = "YOUR_SPOTIFY_CLIENT_ID"
REDIRECT_URI = "http://127.0.0.1:43827/spotify/callback"
SCOPE = "user-modify-playback-state user-read-playback-state user-read-currently-playing user-read-recently-played playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-library-read user-library-modify"
AUTH_JSON_PATH = "/opt/data/auth.json"
TIMEOUT_SECONDS = 600
# ────────────────────────────────────────────────────────────────────────────


def code_verifier(length=64):
    return ''.join(random.choices(string.ascii_letters + string.digits + '-._~', k=length))


def code_challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()


def parse_pasted_callback(raw):
    raw = raw.strip()
    if not raw:
        return {}
    if '?' in raw:
        raw = raw.split('?', 1)[1]
    elif '&' not in raw and '=' not in raw:
        return {"code": raw, "state": None, "error": None}
    params = parse_qs(raw)
    return {
        "code": params.get("code", [None])[0],
        "state": params.get("state", [None])[0],
        "error": params.get("error", [None])[0],
    }


def main():
    verifier = code_verifier()
    challenge = code_challenge(verifier)
    state_nonce = ''.join(random.choices(string.hexdigits, k=32))

    params = {
        'client_id': CLIENT_ID,
        'response_type': 'code',
        'redirect_uri': REDIRECT_URI,
        'scope': SCOPE,
        'state': state_nonce,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
    }
    auth_url = f"https://accounts.spotify.com/authorize?{urlencode(params)}"

    # Write auth URL to file for the agent to read
    with open('/tmp/spotify_auth_url.txt', 'w') as f:
        f.write(auth_url + '\n')
        f.write(REDIRECT_URI + '\n')
        f.write(state_nonce + '\n')
        f.write(verifier + '\n')

    print(f"Auth URL written to /tmp/spotify_auth_url.txt")
    print(f"Waiting for callback paste in /tmp/spotify_callback.txt...")

    # Wait for callback file (poll every 2s, timeout TIMEOUT_SECONDS)
    callback_file = '/tmp/spotify_callback.txt'
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if os.path.exists(callback_file):
            with open(callback_file) as f:
                raw = f.read().strip()
            if raw:
                break
        time.sleep(2)
    else:
        print("TIMEOUT waiting for callback")
        return 1

    # Re-read stored params
    with open('/tmp/spotify_auth_url.txt') as f:
        saved_redirect = f.readline().strip()  # line 2: redirect_uri
        saved_state = f.readline().strip()     # line 3: state
        saved_verifier = f.readline().strip()  # line 4: code_verifier

    callback = parse_pasted_callback(raw)

    if callback.get("error"):
        print(f"Auth error: {callback['error']}")
        return 1
    if not callback.get("code"):
        print("No authorization code found")
        return 1

    print(f"Got authorization code: {callback['code'][:15]}...")

    if callback.get("state") and callback["state"] != saved_state:
        print(f"State mismatch!")
        return 1

    print("Exchanging code for tokens...")
    resp = httpx.post(
        "https://accounts.spotify.com/api/token",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data={
            'client_id': CLIENT_ID,
            'grant_type': 'authorization_code',
            'code': callback['code'],
            'redirect_uri': REDIRECT_URI,
            'code_verifier': saved_verifier,
        },
        timeout=20,
    )
    payload = resp.json()

    if resp.status_code != 200:
        print(f"Token exchange failed ({resp.status_code}): {payload}")
        return 1

    print("Token exchange successful!")

    now = datetime.now(timezone.utc)
    expires_in = payload.get("expires_in", 3600)

    spotify_state = {
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "accounts_base_url": "https://accounts.spotify.com",
        "api_base_url": "https://api.spotify.com/v1",
        "scope": SCOPE,
        "granted_scope": (payload.get("scope") or SCOPE).strip(),
        "token_type": (payload.get("token_type", "Bearer") or "Bearer").strip(),
        "access_token": (payload.get("access_token") or "").strip(),
        "refresh_token": (payload.get("refresh_token") or "").strip(),
        "obtained_at": now.isoformat(),
        "expires_at": (now + timedelta(seconds=expires_in)).isoformat(),
        "expires_in": expires_in,
        "auth_type": "oauth_pkce",
    }

    try:
        with open(AUTH_JSON_PATH) as f:
            store = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        store = {"version": 1, "providers": {}, "active_provider": None, "credential_pool": {}}

    store.setdefault("providers", {})["spotify"] = spotify_state
    store["updated_at"] = now.isoformat()

    with open(AUTH_JSON_PATH, "w") as f:
        json.dump(store, f, indent=2)

    with open('/tmp/spotify_auth_done.txt', 'w') as f:
        f.write('SUCCESS\n')

    print()
    print("SUCCESS! Tokens saved to", AUTH_JSON_PATH)
    return 0


if __name__ == "__main__":
    exit(main())