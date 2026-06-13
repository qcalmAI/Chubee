#!/usr/bin/env bash
# Thin cron wrapper -> canonical detector with the stack (version-controlled).
# Uses HOME so it follows the cron system's HOME=/opt/data/home resolution.
exec bash "$HOME/chubee/stack/arch-drift-check.sh" "$@"