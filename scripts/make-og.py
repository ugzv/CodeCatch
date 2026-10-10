#!/usr/bin/env python3
"""Make each guide's and comparison's share image (site/assets/og/<page>.png, 1200x630).

The image is the page's own heading next to its own app picture, drawn with the site's
styles by headless Chrome, so it changes when the page does. Run it after editing a
page's heading or picture:  python3 scripts/make-og.py
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

TEMPLATE = """<!doctype html>
<html><head><meta charset="utf-8">
<link rel="stylesheet" href="{site}/styles.css">
<style>
  :root {{ color-scheme: light; }}
  html, body {{ width: 1200px; height: 630px; margin: 0; overflow: hidden; }}
  body {{ background: linear-gradient(150deg, #ffad42 0%, #ff5d6c 48%, #b45cf5 100%); color: #fff; }}
  .og {{ display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 56px; height: 100%; padding: 64px 72px; box-sizing: border-box; }}
  .og-copy {{ display: flex; flex-direction: column; justify-content: space-between; height: 100%; }}
  .og-brand {{ display: flex; align-items: center; gap: 12px; font-size: 30px; font-weight: 600; letter-spacing: -0.01em; }}
  .og-brand svg {{ width: 42px; height: 42px; fill: #fff; }}
  .og-kind {{ margin-bottom: 14px; font-size: 26px; font-weight: 600; opacity: 0.85; }}
  .og h1 {{ font-size: 60px; font-weight: 750; letter-spacing: -0.03em; line-height: 1.05; }}
  .og .cc {{ zoom: 1.35; }}
</style></head>
<body>
<main class="og">
  <div class="og-copy">
    <div class="og-brand"><svg viewBox="208 208 608 608"><use href="#mark"/></svg>CodeCatch</div>
    <div><p class="og-kind">{kind}</p><h1>{title}</h1></div>
  </div>
  {art}
</main>
{sprite}
</body></html>
"""


def grab(pattern, html, page):
    match = re.search(pattern, html, re.S)
    if not match:
        sys.exit(f"{page}: nothing matches {pattern}")
    return match.group(1)


def main():
    out_dir = os.path.join(SITE, "assets", "og")
    os.makedirs(out_dir, exist_ok=True)
    work = tempfile.mkdtemp()
    try:
        for page in sorted(glob.glob(os.path.join(SITE, "guides/*/index.html")) + glob.glob(os.path.join(SITE, "vs/*/index.html"))):
            html = open(page).read()
            name = os.path.basename(os.path.dirname(page))
            art = grab(r'<div class="feature-art article-art" aria-hidden="true">\s*(<div class="cc">.*?)\n  </div>\n', html, page)
            source = TEMPLATE.format(
                site="file://" + SITE,
                kind=grab(r'<p class="eyebrow">(.*?)</p>', html, page),
                title=grab(r"<h1>(.*?)</h1>", html, page),
                art=art.replace('src="/assets/', f'src="file://{SITE}/assets/').replace(' loading="lazy"', ""),
                sprite=grab(r'(<svg width="0" height="0".*?</svg>)\s*(?:<script|</body>)', html, page),
            )
            draft = os.path.join(work, name + ".html")
            open(draft, "w").write(source)
            image = os.path.join(out_dir, name + ".png")
            subprocess.run([CHROME, "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                            "--window-size=1200,630", f"--screenshot={image}", "file://" + draft],
                           check=True, capture_output=True)
            if shutil.which("oxipng"):
                subprocess.run(["oxipng", "-q", "-o", "3", "--strip", "safe", image], check=True)
            print(os.path.relpath(image, ROOT), os.path.getsize(image) // 1024, "KB")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
