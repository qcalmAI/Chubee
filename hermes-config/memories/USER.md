Finances in /mnt/chubee-data/personal-docs/Finances/snapshot.json. Scale AI ~$4.9K/biwk, VA $3.9K/mo. Rent $2,495. Crypto cold storage. 401k $1,020/biwk. Stuttgart travel ~12d/mo.
§
User prefers Chubee as the sole interface for all tools — rejected Paperless-ngx because it adds a separate web UI they'd never use. Wants everything accessible through Chubee conversation, not separate dashboards.
§
User wants background/automated jobs to be completely silent unless there's an error. No progress notifications, no completion notifications, no periodic summaries. The crypto price cron job is configured this way: no_agent=true, script-only, zero stdout.
§
When user asks about connecting desktop Hermes to headless Acer: they mean dashboard backend connection (shared sessions), NOT model provider endpoints. If ambiguous, clarify before guessing — getting this wrong frustrates quickly.
§
User is new to GitHub — explain git operations simply, don't assume knowledge. Wants complete recoverability: if Acer dies, restore everything from git onto new machine with no loss of continuity. All config, skills, cron, memories should live in git (secrets excluded). Prefers clean filesystems — no cruft, no stale backups, no relic directories.