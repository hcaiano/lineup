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

The `.github/workflows/deploy-web.yml` workflow stays dormant until a maintainer sets both:

- the repository variable `ENABLE_WEB_DEPLOY` to `true`;
- the Actions secret `CLOUDFLARE_API_TOKEN` to a token limited to Workers Scripts:Edit on the
  Lineup account.

Current deploys are a maintainer-only manual step from an authenticated Wrangler session:

```sh
cd web
npx wrangler deploy
```

Changes go live in seconds.

## Regenerate the social card

```sh
swift web/make-og.swift web/assets/og.png
```
