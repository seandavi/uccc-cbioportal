# UCCC cBioPortal on onclappc02. Runbook: README.md.

set dotenv-load

ch := 'docker compose exec -T cbioportal-database sh -c'

# Compose doesn't see changes inside bind-mounted files. This hash goes into the app's environment,
# so `up` recreates the app exactly when its settings or logo change. Run compose through just.
export UCCC_FILES_SHA := `cat config/uccc.properties config/application.properties branding/uccc_logo.png 2>/dev/null | sha256sum | cut -c1-12`

# The public database dump this deployment was loaded from: cBioPortal's dump_2026_10_18_v3_1_0,
# pinned as a revision of the Hugging Face mirror (upstream keeps only the last five weekly dumps).
dump_repo := 'cBioPortal/publicDatabase'
dump_rev := '58be468cffe7'
dump_root := '/data/davsean/uccc-cbioportal/dump/dump_2026_10_18_v3_1_0'

# List recipes
default:
    @just --list

# Generate config/application.properties and data/ (schema, seed, derived-table SQL) from the pinned image
config:
    test -n "${CLICKHOUSE_PASSWORD:-}" || { echo "set CLICKHOUSE_PASSWORD in .env (see .env.example)"; exit 1; }
    cd config && ./init.sh
    cd data && ./init.sh

# Start or update everything (safe to re-run)
up:
    docker compose up -d

# Deploy a clean checkout. Idempotent: compose recreates only services whose config, image or
# mounted settings changed. Records what was deployed in .deployed.
deploy:
    test -z "$(git status --porcelain --untracked-files=no)" || { echo "uncommitted changes; deploy a clean checkout"; exit 1; }
    docker compose pull -q
    docker compose up -d
    echo "$(git describe --always --dirty) $(git rev-parse --abbrev-ref HEAD) $(date -u +%FT%TZ)" > .deployed

down:
    docker compose down

logs *args:
    docker compose logs -f {{args}}

# Restart the web app (clears its cache; needed after imports and config changes)
restart:
    docker compose restart cbioportal

# Download the pinned dump (87 GB) into dump_root, then verify it
fetch-dump:
    hf download {{dump_repo}} --repo-type dataset --revision {{dump_rev}} --include 'data/*' --include publication.json --local-dir {{dump_root}}
    just verify-dump

# Check every parquet file against the sha256 in the dump's publication.json
verify-dump:
    cd {{dump_root}} && python3 -c 'import json; [print(f["sha256"], f["path"]) for f in json.load(open("publication.json"))["files"]]' | sha256sum -c --quiet && echo DUMP_OK

# Fresh database only: start ClickHouse and load the parquet dump (~1.5 h). Run `just fetch-dump` first.
load-dump:
    docker compose up -d cbioportal-database
    docker compose exec -T cbioportal-database bash /load_parquet.sh

# Validate a study directory under ./study (offline)
validate study:
    docker compose exec cbioportal validateData.py -s /study/{{study}} -n

# Import a study from ./study without rebuilding derived tables; run `just derive-tables` after a batch
import study:
    docker compose exec cbioportal metaImport.py -s /study/{{study}} -o --no-derive-tables

# Rebuild derived tables (built offline as *_temp, swapped in with EXCHANGE TABLES), then restart
derive-tables:
    docker compose exec cbioportal metaImport.py derive-tables
    just restart

# Publish the app on the tailnet at https://onclappc02.tail892754.ts.net:8443
serve-tailnet:
    tailscale serve --bg --https=8443 http://127.0.0.1:8085

# Health check: API up, study count, schema version
check:
    curl -sf http://127.0.0.1:8085/api/health && echo
    curl -sf "http://127.0.0.1:8085/api/studies?projection=SUMMARY&pageSize=10000" | python3 -c "import json,sys; print(len(json.load(sys.stdin)), 'studies')"
    {{ch}} 'clickhouse client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d "$CLICKHOUSE_DB" -q "select db_schema_version from info"'
