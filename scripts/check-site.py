#!/usr/bin/env python3
"""Check the site's pages before they deploy:  python3 scripts/check-site.py

- each page's <html lang> is its folder's language (site/<lang>/..., English at the top);
- an indexed page names itself as canonical and og:url;
- an indexed page outside English names its versions (hreflang), and every version
  names the same ones back, itself among them, with x-default on English;
- the language switcher (the links that carry hreflang) leads to those same versions;
- every link within the site, and its #anchor, leads somewhere;
- a page links to the version of another page in its own language, where there is one
  (the language switcher is the exception);
- the sitemap lists exactly the indexed pages;
- a page that shows dates (<time datetime>) gives its newest one as its dateModified
  and its sitemap lastmod.
"""

import glob
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
ORIGIN = "https://codecatch.app"
LANGUAGES = ["de", "ja", "fr", "it", "es", "pt"]  # besides English; also in functions/_middleware.js


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.lang, self.canonical, self.og_url, self.noindex = None, None, None, False
        self.alternates, self.switcher, self.links, self.ids, self.dates = {}, {}, [], set(), []
        with open(path) as file:
            text = file.read()
        self.modified = set(re.findall(r'"dateModified": "(.*?)"', text))
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        a = {key: value or "" for key, value in attrs}
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "link" and a.get("rel") == "canonical":
            self.canonical = a["href"]
        elif tag == "link" and a.get("rel") == "alternate" and "hreflang" in a:
            self.alternates[a["hreflang"]] = a["href"]
        elif tag == "meta" and a.get("property") == "og:url":
            self.og_url = a["content"]
        elif tag == "meta" and a.get("name") == "robots":
            self.noindex = "noindex" in a["content"]
        elif tag == "time" and "datetime" in a:
            self.dates.append(a["datetime"])
        elif tag == "a" and "href" in a:
            self.links.append((a["href"], "hreflang" in a))
            if "hreflang" in a:
                self.switcher[a["hreflang"]] = a["href"]


def url_of(path):
    rel = os.path.relpath(path, SITE).replace(os.sep, "/")
    return ORIGIN + "/" + rel.removesuffix("index.html")


def file_of(url):
    path = url.removeprefix(ORIGIN).split("#")[0].split("?")[0]
    path = os.path.join(SITE, path.lstrip("/"))
    return os.path.join(path, "index.html") if path.endswith("/") else path


def main():
    errors = []
    paths = sorted(glob.glob(os.path.join(SITE, "**/*.html"), recursive=True))
    pages = {url_of(p): Page(p) for p in paths}
    with open(os.path.join(SITE, "_redirects")) as file:
        redirects = {line.split()[0] for line in file if line.strip()}
    with open(os.path.join(SITE, "sitemap.xml")) as file:
        lastmod = dict(re.findall(r"<loc>(.*?)</loc>(?:<lastmod>(.*?)</lastmod>)?", file.read()))

    for url, page in pages.items():

        def say(message, url=url):
            return errors.append(f"{url.removeprefix(ORIGIN)}: {message}")

        first = url.removeprefix(ORIGIN + "/").split("/")[0]
        lang = first if first in LANGUAGES else "en"
        if page.lang != lang:
            say(f'<html lang="{page.lang}">, but the page is in the {lang} folder')
        indexed = not page.noindex and not url.endswith("404.html")
        if indexed:
            if page.canonical != url:
                say(f"canonical is {page.canonical}")
            if page.og_url != url:
                say(f"og:url is {page.og_url}")
        if page.dates:
            newest = max(page.dates)
            if page.modified != {newest}:
                say(f"dateModified is {', '.join(sorted(page.modified)) or 'missing'}, but the newest date is {newest}")
            if lastmod.get(url, newest) != newest:
                say(f"sitemap lastmod is {lastmod[url] or 'missing'}, but the newest date is {newest}")

        if page.alternates or (indexed and lang != "en"):
            for code in sorted({lang, "en", "x-default"} - page.alternates.keys()):
                say(f"hreflang {code} is missing")
            if page.alternates.get(lang) != url:
                say(f"hreflang {lang} should name the page itself")
            if page.alternates.get("x-default") != page.alternates.get("en"):
                say("x-default should be the English page")
            versions = {code: href for code, href in page.alternates.items() if code != "x-default"}
            if {code: urljoin(url, href) for code, href in page.switcher.items()} != versions:
                say("the language links should lead to the hreflang versions")
            for code, other in page.alternates.items():
                twin = pages.get(other)
                if twin is None:
                    say(f"hreflang {code} leads to {other}, which doesn't exist")
                elif twin.alternates != page.alternates:
                    say(f"hreflang {code} page {other} doesn't name the same versions")
                elif code != "x-default" and twin.lang != code:
                    say(f'hreflang {code} page {other} has <html lang="{twin.lang}">')

        for href, switcher in page.links:
            target = urlsplit(urljoin(url, href))
            if f"{target.scheme}://{target.netloc}" != ORIGIN or target.path in redirects:
                continue  # another site, mailto:, or a redirect in _redirects
            base, anchor = ORIGIN + target.path, target.fragment
            twin = pages.get(base)
            if twin is None and not os.path.isfile(file_of(base)):
                say(f"links to {href}, which doesn't exist")
            elif twin and anchor and anchor not in twin.ids:
                say(f"links to {href}, but that page has no #{anchor}")
            elif twin and not switcher and twin.lang != lang and lang in twin.alternates:
                say(f"links to {href}; link to {twin.alternates[lang].removeprefix(ORIGIN)} instead")

    sitemap = set(lastmod)
    listed = {url for url, page in pages.items() if not page.noindex and not url.endswith("404.html")}
    errors += [f"sitemap.xml: missing {url}" for url in sorted(listed - sitemap)]
    errors += [f"sitemap.xml: {url} is not an indexed page" for url in sorted(sitemap - listed)]

    print("\n".join(errors) or f"{len(pages)} pages OK")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
