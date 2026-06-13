#!/usr/bin/env bash
# Cron wrapper: runs the canonical health check in quiet mode.
# Quiet mode prints NOTHING when green, so the cron job stays silent on healthy
# ticks and only delivers a message when there's a real problem (watchdog pattern).
exec bash "$HOME/chubee/stack/health.sh" --quiet
