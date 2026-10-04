-- D1 database codecatch-installs, filled by functions/_middleware.js. Installs come from Sparkle's daily update checks.
-- Apply: npx wrangler d1 execute codecatch-installs --remote --file scripts/stats.sql
CREATE TABLE IF NOT EXISTS installs (
  id TEXT PRIMARY KEY,        -- the app's random install ID, or "ip:" + a salted IP hash for older builds
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  build TEXT, os TEXT, model TEXT,
  country TEXT, region TEXT, city TEXT, network TEXT,
  checks INTEGER NOT NULL DEFAULT 1
);
-- One row per install per day it checked: daily actives, and updates as build changes between days.
CREATE TABLE IF NOT EXISTS daily (
  day TEXT NOT NULL, id TEXT NOT NULL, build TEXT,
  PRIMARY KEY (day, id)
);
-- Site landings from campaign links (utm_* or ref tags) and every download, see functions/_middleware.js.
CREATE TABLE IF NOT EXISTS site (
  at TEXT NOT NULL,
  kind TEXT NOT NULL,         -- landing or download
  page TEXT,                  -- the codecatch.app page; for a download, the page it was clicked on
  referrer TEXT,              -- the other site it came from, host and path
  source TEXT, medium TEXT, campaign TEXT, content TEXT, term TEXT,  -- utm_* tags; source falls back to ref
  country TEXT, region TEXT, city TEXT, network TEXT,
  os TEXT                     -- macOS, iOS, Windows, Android, Linux or other
);
