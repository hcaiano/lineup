# Lineup website

The landing page for [lineup.caiano.com](https://lineup.caiano.com). A single static page, no build
step, no framework. Served as a Cloudflare Worker with static assets on the Caiano account.

```
web/
  index.html        The page
  styles.css        Brand styles (light + dark)
  robots.txt        Crawl rules
  sitemap.xml       One-URL sitemap
  wrangler.toml     Cloudflare Worker config (name: lineup, serves this dir)
  _headers          Asset caching + security headers
  .assetsignore     Files never served (configs, this README, the og generator)
  vercel.json       Same headers for Vercel, if it's ever hosted there instead
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

## Deploy (Cloudflare)

The site is the `lineup` Worker on the Caiano Cloudflare account, with the custom domain
`lineup.caiano.com` attached (Cloudflare manages the DNS record). The account id is in
`wrangler.toml`; the custom-domain attachment is a one-time setup and survives deploys.

**Automatic (default):** `.github/workflows/deploy-web.yml` deploys on every push to `main`
that touches `web/`. One-time setup: add a repo secret **`CLOUDFLARE_API_TOKEN`** (a token
with *Workers Scripts:Edit* on the Caiano account) under Settings → Secrets and variables →
Actions. You can also run it on demand from the **Actions** tab (Run workflow).

**Manual (fallback):**

```sh
cd web
CLOUDFLARE_API_TOKEN=<token with Workers Scripts:Edit on the Caiano account> npx wrangler deploy
```

Changes go live in seconds.

## Regenerate the social card

```sh
swift web/make-og.swift web/assets/og.png
```
