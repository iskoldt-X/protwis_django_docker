# protwis_django_docker

Python runtime environment for the [protwis](https://github.com/protwis/protwis) Django application, the backbone of [GPCRdb](https://gpcrdb.org).

Designed to work together with [postgres_rdkit_docker](https://github.com/protwis/postgres_rdkit_docker) via a single `docker compose up`.

## Design principles

- **Code-free image.** The protwis source and `data/` tree are bind-mounted at runtime, never baked into the image. Upgrading Python or Django is a pure image rebuild — code is untouched.
- **No conda.** Dependencies are pure-pip via [`uv`](https://github.com/astral-sh/uv); the image is ~5× smaller than the legacy conda-based setup and resolves in seconds.
- **Multi-stage.** Build tools (`build-essential`, `*-dev` headers) live in the builder stage only; the final image ships runtime shared libraries.
- **Version-pinned baseline.** Dependencies mirror the legacy pins verbatim to keep the image a drop-in replacement. Upgrades go through a CI matrix (see `docs/upgrading.md` — TODO).

## Repository layout

```
.
├── Dockerfile              # multi-stage, uv-driven, Python 3.8
├── docker-compose.yml      # app + db (postgres16-rdkit) + adminer
├── pyproject.toml          # single source of truth for Python deps
├── uv.lock                 # generated; commit for reproducibility
└── .github/workflows/
    ├── ci.yml              # build + smoke on every push/PR
    └── docker-publish.yml  # multi-arch push to ghcr.io on tag
```

## Quick start

### Layout expected on disk

```
~/GitHub/
├── protwis/                       # the main Django project (clone separately)
│   └── data/protwis/gpcr/         # gpcrdb_data clone, renamed to `gpcr`
└── protwis_django_docker/         # this repo
```

The default bind-mount paths in `docker-compose.yml` assume this side-by-side layout. Override with `PROTWIS_SRC` / `PROTWIS_DATA` env vars if yours differs.

### One-liner

```bash
cd ~/GitHub/protwis_django_docker
docker compose up --build
```

- **App**: http://localhost:8000
- **Adminer**: http://localhost:8888  (server: `db`, user/pass: `protwis` / `protwis`)
- **PostgreSQL**: `localhost:5432`

First startup takes a few minutes: the app image builds, the DB initializes, and compose waits for the DB healthcheck before starting the app.

### Loading the GPCRdb dump

See the `postgres_rdkit_docker` README for the authoritative instructions. Short version:

```bash
curl -L https://files.gpcrdb.org/protwis_sp.sql.gz -o ~/protwis.sql.gz
gunzip -c ~/protwis.sql.gz | docker exec -i protwis-db psql -U protwis -d protwis -q -1
```

## Development workflow

Because the source is bind-mounted, code edits on the host are live inside the container. Django's `runserver` auto-reloads.

Common commands:

```bash
# Shell into the app container
docker compose exec app bash

# Run Django management commands
docker compose exec app python manage.py migrate
docker compose exec app python manage.py build_drugs_updated

# Tail logs
docker compose logs -f app

# Rebuild after pyproject.toml changes
docker compose build app
```

## Upgrading dependencies

The whole point of this repo: make dependency upgrades testable in CI instead of untestable on someone's laptop.

1. Edit `pyproject.toml` (bump a single pin).
2. Regenerate the lock: `uv lock`.
3. Push — GitHub Actions builds the image and runs smoke tests (Django import, `manage.py check`, critical deps).
4. If green, merge. If red, the error points at the exact breakage.

A future `docs/upgrading.md` will codify the Python 3.8 → 3.11 → 3.12 and Django 2.2 → 3.2 → 4.2 ladders.

## CI

- **`ci.yml`** — on every push/PR: builds the image and runs three smoke tests (deps import, critical scientific libs import, a minimal `manage.py check`).
- **`docker-publish.yml`** — on `v*` tag: builds multi-arch (amd64 + arm64) and pushes to `ghcr.io/protwis/protwis_django_docker`.

## License

Apache-2.0 — see [LICENSE](LICENSE).
