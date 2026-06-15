#!/usr/bin/env python3
"""Resolve a creator, channel URL, video URL, or topic into a list of YouTube videos via yt-dlp.
Output: JSON {mode, resolved, count, videos:[{id, title, url}]}"""

import argparse, json, subprocess, sys, os

YT_DLP = os.path.expanduser("~/.local/bin/yt-dlp")

def run_ytdlp(args):
    cmd = [YT_DLP, "--flat-playlist", "--print", "%(id)s|%(title)s|%(webpage_url)s"] + args
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return [l for l in r.stdout.strip().split("\n") if l.strip()]
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)

def parse_lines(lines, name, mode):
    videos = []
    for line in lines:
        parts = line.split("|", 2)
        vid_id = parts[0].strip()
        title = parts[1].strip() if len(parts) > 1 else ""
        url = parts[2].strip() if len(parts) > 2 else f"https://youtube.com/watch?v={vid_id}"
        videos.append({"id": vid_id, "title": title, "url": url})
    return {"mode": mode, "resolved": name, "count": len(videos), "videos": videos}

def is_url(s): return s.startswith("http://") or s.startswith("https://")
def is_channel(s): return "/channel/" in s or "/@" in s or "/c/" in s or "/user/" in s

def resolve_channel(inp):
    url = inp if is_url(inp) else f"https://www.youtube.com/@{inp}"
    lines = run_ytdlp([url])
    return parse_lines(lines, inp, "channel")

def resolve_topic(query, limit=30):
    lines = run_ytdlp([f"ytsearch{limit}:{query}"])
    return parse_lines(lines, query, "topic")

def resolve_video(url):
    r = subprocess.run([YT_DLP, "--print", "%(channel_url)s", url], capture_output=True, text=True, timeout=30)
    channel_url = r.stdout.strip()
    lines = run_ytdlp([channel_url])
    return parse_lines(lines, channel_url, "video\u2192channel")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    p.add_argument("--limit", type=int, default=None)
    args = p.parse_args()
    inp = args.input.strip()
    if is_url(inp) and ("/watch" in inp or "/shorts/" in inp):
        result = resolve_video(inp)
    elif is_url(inp) and is_channel(inp):
        result = resolve_channel(inp)
    elif is_url(inp):
        result = resolve_channel(inp)
    else:
        result = resolve_topic(inp, args.limit or 30)
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()

