#!/usr/bin/env python3
import os, smtplib, psycopg2, requests
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from dotenv import load_dotenv

load_dotenv(os.path.expanduser("~/chubee/stack/.env"))

PG = dict(host="localhost", port=5432,
    user=os.environ["POSTGRES_USER"],
    password=os.environ["POSTGRES_PASSWORD"],
    database=os.environ["POSTGRES_DB"])

def recent_memories():
    week_ago = datetime.utcnow() - timedelta(days=7)
    with psycopg2.connect(**PG) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT content, category, importance FROM memories "
                "WHERE created_at >= %s ORDER BY importance DESC, created_at DESC LIMIT 30",
                (week_ago,))
            return cur.fetchall()

def llm_synthesize(memories):
    bullet_list = "\n".join(f"- [{c}/{i}] {m}" for m, c, i in memories)
    prompt = (
        "You are Chubee. Write a brief, direct weekly briefing.\n\n"
        f"Memories captured this week:\n{bullet_list}\n\n"
        "Format: 4-6 paragraphs. Lead with what changed or progressed. "
        "Note patterns. End with anything needing Quinton's attention. Skip filler."
    )
    resp = requests.post(
        "http://localhost:4000/v1/chat/completions",
        headers={"Authorization": f"Bearer {os.environ['LITELLM_MASTER_KEY']}"},
        json={"model": "primary_model",
              "messages": [{"role": "user", "content": prompt}],
              "temperature": 0.3},
        timeout=300)
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]

def send_email(subject, body):
    msg = MIMEMultipart()
    msg["From"] = os.environ["CHUBEE_EMAIL"]
    msg["To"] = os.environ["PERSONAL_EMAIL"]
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))
    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as smtp:
        smtp.login(os.environ["CHUBEE_EMAIL"], os.environ["CHUBEE_GMAIL_APP_PASSWORD"])
        smtp.send_message(msg)

if __name__ == "__main__":
    memories = recent_memories()
    body = "Quiet week. No new memories captured." if not memories else llm_synthesize(memories)
    body += "\n\n\u2014 Chubee\nby Quinton's assistant. Sent automatically; no review."
    send_email(f"Chubee briefing \u2014 {datetime.now():%Y-%m-%d}", body)
