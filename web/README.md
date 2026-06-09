# Lineup website

The landing page for [lineup.caiano.com](https://lineup.caiano.com). A single static page, no build
step, no framework.

```
web/
  index.html        The page
  styles.css        Brand styles (light + dark)
  robots.txt        Crawl rules
  sitemap.xml       One-URL sitemap
  vercel.json       Clean URLs + caching/security headers
  make-og.swift     Regenerates the social card
  assets/
    icon.png        App icon (favicon, hero)
    editor.png      Editor screenshot
    og.png          Open Graph / social card (1200x630)
```

## Preview locally

```sh
cd web && python3 -m http.server 8799
# open http://localhost:8799
```

## Deploy to Vercel

1. Create a Vercel project from this repo and set the **Root Directory** to `web`. There is no build
   command and no framework. The output directory is the root (`.`).
2. Add the domain **lineup.caiano.com** in the project's Domains settings and point a `CNAME` for
   `lineup` at Vercel (`cname.vercel-dns.com`) in the `caiano.com` DNS.

## Regenerate the social card

```sh
swift web/make-og.swift web/assets/og.png
```
