# Escalation Protocol — Reference

## Policy: Manual Only

> Escalation to the frontier model is a **user decision** only. The agent never autonomously switches models, delegates to frontier, or injects a model change. If Qwen fails, it fails.

## Log Format Specification

Log file: `~/chubee/frontier-usage.log`

### Header
```
# Frontier Usage Log
# Format: YYYY-MM-DD HH:MM | task | reason
```

### Entry Format
Each entry is one line:
```
YYYY-MM-DD HH:MM | <one-line task description> | <reason>
```

### Valid Reasons
| Reason | Trigger |
|--------|---------|
| `constraints` | Sustained multi-step logic across 5+ interdependent constraints |
| `quality` | Output where quality > speed (legal, financial, architecture, important correspondence) |
| `self-assessment` | First local output judged insufficient — do NOT attempt a second pass |
| `user-request` | User explicitly asked for best possible output |

### Example Entries
```
2026-06-05 18:32 | Design database migration strategy for 200-table schema | constraints
2026-06-05 19:15 | Draft legal terms for data processing agreement | quality
2026-06-05 19:25 | Debug complex distributed locking bug | self-assessment
2026-06-05 20:00 | Analyze this compliance document thoroughly | user-request
```

## Cron Job Setup

Created via `cronjob` tool:

**Name:** `weekly-frontier-report`
**Schedule:** `0 9 * * 0` (Sundays at 9am local time)
**Toolsets:** `file`, `messaging`
**Delivery:** Telegram DM to `telegram:Q`

### Cron Prompt (canonical)

```
Generate the weekly frontier usage report and send it to Quinton via Telegram.

Read ~/chubee/frontier-usage.log. Filter entries from the past 7 days
(exclude lines starting with #). Count total escalations, group by reason
category, and list each escalation on its own line.

Send a Telegram DM to the target 'telegram:Q' with this message format:

📊 **Weekly Frontier Usage Report**

**Escalations this week:** {count}

**Breakdown by reason:**
• {reason1}: {count}
• {reason2}: {count}

**Details:**
{one-line-per-escalation}

**Assessment:**
- 0-4/week: ✅ Low volume — second Spark not warranted
- 5-9/week: 👀 Moderate — continue monitoring
- 10+/week: ⚠️ Second Spark worth serious evaluation

If count is 0 send:
"📊 **Weekly Frontier Usage Report**
**Escalations this week:** 0
✅ No frontier usage this week — Qwen handled everything."

Only send the Telegram message — do not save anything or create files.
```

### Verification

```bash
# Check cron exists
send_message(action='list')  # Verify telegram:Q target exists

# Manual test: check log
cat ~/chubee/frontier-usage.log

# Expected header format
# # Frontier Usage Log
# # Format: YYYY-MM-DD HH:MM | task | reason
# 2026-06-07 10:00 | Example escalation | constraints
```

## Decision Framework — Extended

### When to Stay Local (Qwen)

Qwen2.5-32B handles all of these well:
- Terminal commands, Docker operations, file edits
- Coding tasks (single-file or moderate multi-file changes)
- Web searches and content extraction
- Routine data analysis and formatting
- Standard troubleshooting
- Procedural workflows (install, configure, deploy)
- Any mechanical or repetitive task

### When to Inform the User (offer, don't act)

The 32B model may struggle with:
- Multi-step reasoning chains where each step depends on the previous (5+ interdependent constraints)
- Legal, medical, or financial analysis requiring precision
- Architectural decisions that will impact the system for months
- Tasks where a mistake would be costly or hard to undo

When you identify one of these, **tell the user** — do not autonomously switch to the frontier model. Let them decide.

### The Meta-Rule

> If you're unsure whether to inform the user, ask: "If I get this wrong with Qwen, how bad is it?"
> - **Trivial redo** → stay quiet and keep working
> - **Costly mistake** → inform the user and let them decide
> - **Still unsure** → inform the user — they'd rather know

## Weekly Report Assessment Guide

The Sunday cron assesses escalations/week to answer: "Should we buy a second Spark for the frontier model?"

| Rate | Assessment | Action |
|------|-----------|--------|
| 0-4 | ✅ Low | No action needed. Qwen is sufficient. |
| 5-9 | 👀 Moderate | Mention in Telegram summary. Start tracking trend. |
| 10+ | ⚠️ High | Recommend evaluating a second Spark. Note the dominant reason categories. |

The decision to buy hardware depends on:
1. **Volume**: How many tasks genuinely exceed 32B capability per week
2. **Criticality**: How many of those are high-stakes (quality trigger)
3. **Cost comparison**: Weekly OpenRouter cost vs. amortized hardware cost
4. **User judgement**: The user ultimately decides