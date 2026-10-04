#!/bin/bash
# Shows who visits, downloads and runs CodeCatch, from what functions/_middleware.js records
# in the D1 database codecatch-installs (page views overall are in Cloudflare Web Analytics).
#   scripts/stats.sh           downloads, campaigns, then installs, versions and updates
# Needs Cloudflare credentials in the environment: CLOUDFLARE_ACCOUNT_ID, and either
# CLOUDFLARE_API_TOKEN (D1 read) or CLOUDFLARE_API_KEY with CLOUDFLARE_EMAIL.
set -euo pipefail
SINCE7="strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days')"
SINCE30="strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days')"
show() {
    printf '\n%s\n' "$1"
    npx --yes wrangler@4.147.0 d1 execute codecatch-installs --remote --json --command "$2" 2>/dev/null \
        | jq -r '.[0].results | if length == 0 then "  (none)" else (.[0] | keys_unsorted | @tsv), (.[] | map(. // "-") | @tsv) end' \
        | column -t -s $'\t'
}
show "Downloads per day, last 30 days" \
    "SELECT substr(at, 1, 10) AS day, count(*) AS downloads, sum(os = 'macOS') AS from_macs FROM site
    WHERE kind = 'download' AND at >= $SINCE30 GROUP BY day ORDER BY day DESC"
show "Where downloads came from, last 30 days" \
    "SELECT coalesce(source, referrer, iif(page IS NULL, 'direct', 'site')) AS source, campaign, page, count(*) AS downloads FROM site
    WHERE kind = 'download' AND at >= $SINCE30 GROUP BY 1, 2, 3 ORDER BY downloads DESC LIMIT 30"
show "Campaigns, last 30 days (landings from utm or ref links, and the downloads they led to on that page)" \
    "SELECT source, medium, campaign, sum(kind = 'landing') AS landings, sum(kind = 'download') AS downloads FROM site
    WHERE source IS NOT NULL AND at >= $SINCE30 GROUP BY 1, 2, 3 ORDER BY landings DESC LIMIT 30"
show "Download countries, last 30 days" \
    "SELECT country, count(*) AS downloads FROM site WHERE kind = 'download' AND at >= $SINCE30
    GROUP BY country ORDER BY downloads DESC LIMIT 20"
show "Active installs" "SELECT
    (SELECT count(DISTINCT id) FROM daily WHERE day >= date('now', '-1 day')) AS last_24h,
    (SELECT count(DISTINCT id) FROM daily WHERE day >= date('now', '-7 days')) AS last_7d,
    (SELECT count(DISTINCT id) FROM daily WHERE day >= date('now', '-30 days')) AS last_30d,
    (SELECT count(*) FROM installs) AS ever"
show "Builds, active in the last 7 days (no build: older than the install ID)" \
    "SELECT build, count(*) AS installs FROM installs WHERE last_seen >= $SINCE7 GROUP BY build ORDER BY CAST(build AS INTEGER) DESC"
show "Countries, active in the last 7 days" \
    "SELECT country, count(*) AS installs FROM installs WHERE last_seen >= $SINCE7 GROUP BY country ORDER BY installs DESC"
show "Updates in the last 30 days" "WITH seen AS (
    SELECT day, id, build, lag(build) OVER (PARTITION BY id ORDER BY day) AS previous FROM daily WHERE build IS NOT NULL)
    SELECT day, substr(id, 1, 8) AS install, previous AS from_build, build AS to_build FROM seen
    WHERE previous != build AND day >= date('now', '-30 days') ORDER BY day DESC"
show "Latest 50 installs" "SELECT substr(id, 1, 8) AS install, build, os, model, country, city, network,
    substr(first_seen, 1, 10) AS first_seen, substr(last_seen, 1, 16) AS last_seen, checks
    FROM installs ORDER BY last_seen DESC LIMIT 50"
