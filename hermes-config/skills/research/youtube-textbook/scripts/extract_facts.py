#!/usr/bin/env python3
"""Extract atomic facts from a YouTube transcript via local Nemotron vLLM API.
Input: transcript on stdin + --title, --scope, --vid args
Output: JSON {vid, title, facts:[{topic, fact}]}
Uses streaming with 30s idle timeout. Chunks long transcripts (12K-char windows)."""

import argparse, json, sys, time
import urllib.request, urllib.error

VLLM_URL = "http://172.17.0.1:8000/v1/chat/completions"
MODEL = "nemotron-nano-30b"
MAX_CHARS_PER_CHUNK = 12000
IDLE_TIMEOUT = 30
MAX_TOKENS = 3000
MAX_RETRIES = 1

def chunk_transcript(text, max_chars=MAX_CHARS_PER_CHUNK):
    """Split transcript into ~max_char chunks at sentence boundaries."""
    chunks = []
    current = ""
    for char in text:
        current += char
        if len(current) >= max_chars and char in ".!?\n":
            chunks.append(current.strip())
            current = ""
    if current.strip():
        chunks.append(current.strip())
    return chunks

def call_nemotron(system_prompt, user_prompt):
    """Streaming call to local Nemotron with idle timeout."""
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.3,
        "stream": True
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(VLLM_URL, data=data, headers={"Content-Type": "application/json"})
    
    try:
        resp = urllib.request.urlopen(req, timeout=IDLE_TIMEOUT)
        full_content = ""
        last_token_time = time.time()
        buf = b""
        
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            buf += chunk
            
            # Process SSE lines
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.decode().strip()
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        msg = json.loads(data_str)
                        delta = msg.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            full_content += content
                            last_token_time = time.time()
                    except json.JSONDecodeError:
                        pass
            
            # Idle timeout check
            if time.time() - last_token_time > IDLE_TIMEOUT:
                break
        
        return full_content
    except Exception as e:
        return None

def extract_from_chunk(title, scope, vid, transcript_text):
    """Extract facts from one chunk of transcript."""
    system = f"You are extracting atomic facts from a YouTube video transcript. Video title: {title}. Scope: {scope}. Output ONLY valid JSON: {{\"facts\": [{{\"topic\": \"...\", \"fact\": \"...\"}}]}}. Each fact must be self-contained and substantive. Skip chatter, intros, sponsor reads, filler."
    user = f"Transcript (video: {vid}):\n\n{transcript_text}"
    
    for attempt in range(MAX_RETRIES = 1
        content = call_nemotron(system, user)
        if content is None:
            continue
        # Try to extract JSON from content
        content = content.strip()
        if content.startswith("```"):
            content = content.split("```")[1]
            if content.startswith("json"):
                content = content[4:]
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            # Try to find JSON array/object in the content
            import re
            m = re.search(r'\{[^}]*"facts"\s*:\s*\[.*?\]\s*\}', content, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group())
                except:
                    pass
    return {"facts": []}

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--title", required=True)
    p.add_argument("--scope", required=True)
    p.add_argument("--vid", required=True)
    args = p.parse_args()
    
    transcript = sys.stdin.read()
    if not transcript.strip():
        print(json.dumps({"vid": args.vid, "title": args.title, "facts": [], "error": "empty transcript"}))
        return
    
    chunks = chunk_transcript(transcript)
    all_facts = []
    
    for i, chunk in enumerate(chunks):
        result = extract_from_chunk(args.title, args.scope, args.vid, chunk)
        facts = result.get("facts", [])
        all_facts.extend(facts)
    
    # Dedup within video
    seen = set()
    unique = []
    for f in all_facts:
        key = (f.get("topic", ""), f.get("fact", ""))
        if key not in seen:
            seen.add(key)
            unique.append(f)
    
    print(json.dumps({
        "vid": args.vid,
        "title": args.title,
        "facts": unique
    }, indent=2))

if __name__ == "__main__":
    main()

