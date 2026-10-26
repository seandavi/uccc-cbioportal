# uccc-cbioportal

A [cBioPortal](https://www.cbioportal.org/) instance for the University of Colorado Anschutz Cancer
Center (UCCC). It holds every public cbioportal.org study, and UCCC disease groups can add public
cohorts to it.

| | |
|---|---|
| Public | https://uccc-cbioportal.cancerdatasci.org (Cloudflare-proxied, through Traefik) |
| Tailnet | https://onclappc02.tail892754.ts.net:8443 (`tailscale serve`) |
| Host | onclappc02 |
| cBioPortal | `cbioportal/cbioportal:7.2.1`, database schema 3.1.0, ClickHouse 24.10 |
| Data | the cbioportal.org public database dump, snapshot 2026-10-22: 551 studies, 193 GB in ClickHouse |

## How this repo is put together

- `docker-compose.yml`, `entrypoint.sh`, `config/init.sh`, `data/*.sh`, `LICENSE` are copied
  unchanged from [cbioportal-docker-compose](https://github.com/cBioPortal/cbioportal-docker-compose)
  at commit `04c144b`. Don't edit them; re-copy them on upgrade.
- `docker-compose.override.yml` holds everything UCCC-specific:
  - localhost-only ports and the Traefik labels
  - the logo mount and the settings overlay
  - loading the database from the parquet dump
  - the pinned volume names
- `config/uccc.properties` holds only the settings we change (branding, allowed origins). It is
  layered over the image's own `application.properties` through `SPRING_CONFIG_ADDITIONALLOCATION`,
  so upgrades don't mean merging a 400-line file.
- Generated, gitignored: `.env` (holds the ClickHouse password), `config/application.properties`
  and `data/` (schema, seed and derived-table SQL taken from the image by `just config`).

## Runbook

```bash
cp .env.example .env        # set CLICKHOUSE_PASSWORD; set CBIO_DUMP_DIR if the dump isn't in the default place
just config                 # generate config/application.properties and data/ from the pinned image
just load-dump              # fresh database only: loads the parquet dump (~1.5 h)
just up                     # start or update; safe to re-run
just serve-tailnet          # once per host
just check                  # API health, study count, schema version
```

### Add a study

1. Put the study folder in `./study/<id>`. It needs `meta_study.txt` plus clinical files at minimum;
   see [cBioPortal's file formats](https://docs.cbioportal.org/file-formats/).
2. `just validate <id>`
3. `just import <id>`. This skips the derived-table rebuild, so you can import a batch.
4. `just derive-tables`. It rebuilds the derived tables offline as `*_temp`, swaps them in with
   `EXCHANGE TABLES`, then restarts the app. The cBioPortal docs still describe an older
   empty-then-refill behavior (cBioPortal#12453).

Overwriting a study that's already loaded changes its live base tables mid-import. For that, use a
second database (see the issues).

### Upgrade cBioPortal

1. Bump `DOCKER_IMAGE_CBIOPORTAL` in `.env.example` and `.env`.
2. Re-copy the upstream files listed above.
3. `just config`, then `just up`. The `cbioportal-migration` service brings the schema up to date
   before the app starts, and the app refuses to start if the schema version doesn't match.

## Query limits

The portal is public and accepts any combination of studies and genes, so the web app's queries
are capped:

- **Each query:** 90 s, 16 GiB and 16 threads. These are set in `spring.datasource.url` in
  `config/uccc.properties`, and they don't apply to imports or `derive-tables`.
- **ClickHouse overall:** `mem_limit: 192g`. ClickHouse refuses work above about 173 GB, which is
  0.9 of that limit.

Measured 2026-10-26 through headless Chromium, with no limits set:

| Page | Load time |
|---|---|
| `msk_impact_50k_2026` study summary | 18 s |
| BRCA PanCancer co-expression (ERBB2) | 37 s |
| `msk_chord_2024` study summary | 7 s |

The slowest query took 16.7 s on a cold cache and 0.5 s warm. Peak memory for one query was
1.7 GiB. Capping a query at 16 threads doubles that warm query to 1 s.

## Gotchas found while setting this up

- The image serves custom images from `/cbioportal-webapp/webapp/images/`, not the path in the
  docs (cBioPortal#12454). The mounted file must be readable by the container user.
- Don't set `server.forward-headers-strategy=NATIVE` behind `tailscale serve`. It drops the `:8443`
  port from the URLs the page builds, so the app's JavaScript loads from the wrong port.
- `/api/studies?projection=ID` returns `[]`; use `projection=SUMMARY`.
