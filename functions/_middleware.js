// Server-side stats for codecatch.app, without cookies, into the D1 database in scripts/stats.sql:
// - update checks: Sparkle fetching the appcast, with the id, build, os and model the app adds
//   (Sources/CodeCatch/System/Updater.swift), count installs and versions;
// - landings: a page opened from a campaign link (utm_* or ref tags);
// - downloads: every /download/CodeCatch.dmg, with the page and campaign it came from.
// Every response is served as is: recording runs after it and its errors are dropped.
// Bindings, set on the Pages project: DB (D1 codecatch-installs) and SALT (secret).
const BOT = /bot|crawl|spider|slurp|preview|headless/i;

export async function onRequest({ request, env, next, waitUntil }) {
  const response = await next();
  const task = env.DB && request.method === "GET" && record(request, env, response);
  if (task) waitUntil(task.catch((error) => console.error("stats", error)));
  return response;
}

function record(request, env, response) {
  const url = new URL(request.url), agent = request.headers.get("user-agent") ?? "";
  if (BOT.test(agent)) return null;
  if (url.pathname === "/appcast.xml") return agent.includes("Sparkle/") ? updateCheck(request, env, url) : null;
  if (url.pathname === "/download/CodeCatch.dmg") return siteEvent(request, env, url, "download");
  if (tagged(url) && response.headers.get("content-type")?.startsWith("text/html")) return siteEvent(request, env, url, "landing");
  return null;
}

const tagged = (url) => url.searchParams.has("ref") || [...url.searchParams.keys()].some((key) => key.startsWith("utm_"));
const value = (params, key) => params.get(key)?.slice(0, 128) || null;
const where = (cf = {}) => [cf.country ?? null, cf.region ?? null, cf.city ?? null, cf.asOrganization ?? null];

async function updateCheck(request, env, url) {
  const params = url.searchParams, build = value(params, "build");
  // Older builds send nothing, so their installs are told apart by IP, which is never stored as is.
  const id = value(params, "id") ?? "ip:" + (await hash(env.SALT + request.headers.get("cf-connecting-ip")));
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO installs (id, first_seen, last_seen, build, os, model, country, region, city, network)
      VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      ON CONFLICT (id) DO UPDATE SET last_seen = ?2, build = coalesce(?3, build), os = coalesce(?4, os),
        model = coalesce(?5, model), country = ?6, region = ?7, city = ?8, network = ?9, checks = checks + 1`)
      .bind(id, now, build, value(params, "os"), value(params, "model"), ...where(request.cf)),
    env.DB.prepare(`INSERT INTO daily (day, id, build) VALUES (?1, ?2, ?3)
      ON CONFLICT (day, id) DO UPDATE SET build = coalesce(?3, build)`).bind(now.slice(0, 10), id, build),
  ]);
}

// A download clicked on the site carries its page, and that page's tags, in the Referer;
// a link from elsewhere (the README, a post) carries the other site, and any tags of its own.
async function siteEvent(request, env, url, kind) {
  let page = kind === "landing" ? url.pathname : null, from = null, tags = url;
  const referer = URL.parse(request.headers.get("referer") ?? "");
  if (referer && referer.host !== url.host) from = (referer.host + referer.pathname).slice(0, 128);
  else if (referer && kind === "download") { page = referer.pathname; if (tagged(referer)) tags = referer; }
  const params = tags.searchParams;
  await env.DB.prepare(`INSERT INTO site (at, kind, page, referrer, source, medium, campaign, content, term, country, region, city, network, os)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)`)
    .bind(new Date().toISOString(), kind, page, from, value(params, "utm_source") ?? value(params, "ref"), value(params, "utm_medium"),
      value(params, "utm_campaign"), value(params, "utm_content"), value(params, "utm_term"), ...where(request.cf), system(request.headers.get("user-agent")))
    .run();
}

const system = (agent) => /iPhone|iPad/.test(agent) ? "iOS" : /Mac OS X/.test(agent) ? "macOS" : /Windows/.test(agent) ? "Windows"
  : /Android/.test(agent) ? "Android" : /Linux/.test(agent) ? "Linux" : "other";

async function hash(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest).slice(0, 8)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
