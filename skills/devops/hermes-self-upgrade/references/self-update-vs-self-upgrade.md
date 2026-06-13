# When to use self-update vs hermes-self-upgrade

- **self-update** (dogfood skill): Routine Docker update — `git pull`, `docker compose build`, `rm -f` + `up -d`. No merge conflicts, no major version jump. The agent stays alive through the whole process since it only needs `docker exec` access. This covers 90% of updates.

- **hermes-self-upgrade**: Full upstream fork merge with potential conflicts. Used when upstream has diverged significantly or the agent's own Docker image is being rebuilt. The dangerous cutover step (`docker compose up -d --force-recreate`) kills the agent, requiring external operator handoff.

Key difference: self-update never kills the agent (it runs `docker rm -f hermes` but the session survives because the terminal tool is on the host, not inside the hermes container). hermes-self-upgrade kills the agent because the gateway container itself is recreated.
