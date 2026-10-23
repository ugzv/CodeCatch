#!/usr/bin/env python3
"""Make the share images, 1200x630: each home page's (the file its og:image names) and
each guide's and comparison's (site/assets/og/<page>.png; site/assets/og/<lang>/<page>.png
for a page in another language).

The image is the page's own heading next to its own app picture, drawn with the site's
styles by headless Chrome, so it changes when the page does. On the home page that
picture is the hero, stopped once the text code is copied and pasted. Run it after
editing a page's heading or picture:  python3 scripts/make-og.py
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
<html lang="{lang}"><head><meta charset="utf-8">
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
{style}
</style></head>
<body>
<main class="og">
  <div class="og-copy">
    <div class="og-brand"><svg viewBox="208 208 608 608"><use href="#mark"/></svg>CodeCatch</div>
    <div>{kind}<h1>{title}</h1></div>
  </div>
  {art}
</main>
{sprite}
</body></html>
"""

# The hero stage stands at the right and runs off the bottom; its chips are enlarged
# so the three kinds of message stay readable in a small link preview.
HOME_STYLE = """
  .og { position: relative; display: block; }
  .og-copy { width: 460px; }
  .og .stage { position: absolute; right: 40px; top: 52px; width: 600px; height: 600px; aspect-ratio: auto;
    color: var(--text); box-shadow: 0 30px 80px rgba(60, 10, 40, 0.35), 0 0 0 1px rgba(255, 255, 255, 0.35); }
  .og .banner { zoom: 1; }
  .og .types { zoom: 1.3; top: 34px; }
  .og .types button { opacity: 0.8; }
  .og .types button.on { opacity: 1; }
  /* Still, or a late web font can catch the hidden link banner sliding into view. */
  .og .stage * { transition: none; animation: none; }
"""


def still(stage, page):
    """The hero's text scene at its end: the banner in, its code copied and pasted."""
    code = grab(r'id="banner-code">([^<]+)<', stage, page)
    for old, new in [
        ('class="cc banner" id="banner"', 'class="cc banner on" id="banner"'),
        ('<b id="menubar-code"></b>', f'<b id="menubar-code">{code}</b>'),
        ('class="page-input" id="otp"', 'class="page-input on" id="otp"'),
        ('<span id="otp-text"></span><i class="caret"></i>', f'<span id="otp-text">{code.replace(" ", "")}</span>'),
        ('class="keys" id="keys"', 'class="keys on" id="keys"'),
        ('class="pill prominent" id="banner-copy"', 'class="pill prominent copied" id="banner-copy"'),
        ('<use href="#i-copy"/></svg><span>Copy</span>', '<use href="#i-check"/></svg><span>Copied</span>'),
    ]:
        if old not in stage:
            sys.exit(f"{page}: the hero has no {old}")
        stage = stage.replace(old, new)
    stage, lit = re.subn(
        r'(<div class="types" id="types" aria-hidden="true">\s*<button)', r'\1 class="on"', stage, count=1
    )
    if not lit:
        sys.exit(f"{page}: the hero has no chips")
    return stage


def grab(pattern, html, page):
    match = re.search(pattern, html, re.DOTALL)
    if not match:
        sys.exit(f"{page}: nothing matches {pattern}")
    return match.group(1)


def main():
    out_dir = os.path.join(SITE, "assets", "og")
    work = tempfile.mkdtemp()
    try:
        for page in sorted(glob.glob(os.path.join(SITE, "**/index.html"), recursive=True)):
            with open(page) as file:
                html = file.read()
            lang = grab(r'<html lang="([a-z-]+)"', html, page)
            folder = out_dir if lang == "en" else os.path.join(out_dir, lang)
            if 'id="stage"' in html:
                # Each home page names its own image (og.png, og/de/start.png, og/fr/accueil.png...).
                image = os.path.join(
                    SITE, grab(r'<meta property="og:image" content="https://codecatch.app/([^"]+)"', html, page)
                )
                name, style, kind = "home", HOME_STYLE, ""
                title = grab(r'<section class="hero">.*?<h1>(.*?)</h1>', html, page)
                art = still(grab(r'(<div class="stage" id="stage".*?)\n</section>', html, page), page)
            elif 'class="feature-art article-art"' in html:
                name, style = os.path.basename(os.path.dirname(page)), ""
                image = os.path.join(folder, name + ".png")
                kind = '<p class="og-kind">' + grab(r'<p class="eyebrow">(.*?)</p>', html, page) + "</p>"
                title = grab(r"<h1>(.*?)</h1>", html, page)
                art = grab(
                    r'<div class="feature-art article-art" aria-hidden="true">\s*(<div class="cc">.*?)\n  </div>\n',
                    html,
                    page,
                )
            else:
                continue
            os.makedirs(os.path.dirname(image), exist_ok=True)
            source = TEMPLATE.format(
                lang=lang,
                site="file://" + SITE,
                style=style,
                kind=kind,
                title=title,
                art=art.replace('src="/assets/', f'src="file://{SITE}/assets/').replace(' loading="lazy"', ""),
                sprite=grab(r'(<svg width="0" height="0".*?</svg>)\s*(?:<script|</body>)', html, page),
            )
            draft = os.path.join(work, lang + "-" + name + ".html")
            with open(draft, "w") as file:
                file.write(source)
            subprocess.run(
                [
                    CHROME,
                    "--headless",
                    "--hide-scrollbars",
                    "--force-device-scale-factor=1",
                    "--window-size=1200,630",
                    f"--screenshot={image}",
                    "file://" + draft,
                ],
                check=True,
                capture_output=True,
            )
            if shutil.which("oxipng"):
                subprocess.run(["oxipng", "-q", "-o", "3", "--strip", "safe", image], check=True)
            print(os.path.relpath(image, ROOT), os.path.getsize(image) // 1024, "KB")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
