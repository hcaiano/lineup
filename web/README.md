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
`lineup.caiano.com` attached (Cloudflare manages the DNS record). To ship changes:

```sh
cd web
CLOUDFLARE_ACCOUNT_ID=8fb78b17553e40987100290645e00bbc \
CLOUDFLARE_API_TOKEN=<token with Workers Scripts:Edit on the Caiano account> \
npx wrangler deploy
```

Changes go live in seconds. The custom-domain attachment is a one-time setup and survives deploys.

## Regenerate the social card

```sh
swift web/make-og.swift web/assets/og.png
```
