# Foldseek Integration: Production Reality and the Containerized Future

This document describes how the **structure similarity search** feature
(`gpcrdb.org/structure/structure_similarity_search/`) is implemented today
in production, what design problems that implementation solves, and how
the same feature should be implemented in the `protwis_django_docker`
world. It is a design document, not an implementation — no code in this
repository or in `protwis` is changed by it.

The audience is anyone evaluating whether `protwis_django_docker` can
eventually cover production needs, not just developer-local needs.

---

## TL;DR

Production today runs the Foldseek CLI in a **sibling Docker container**
spawned per request by Django via the `docker` Python SDK. The most
important property of that design — whether or not the author thought of
it in these terms — is a **filesystem sandbox around an untrusted user
upload being parsed by a complex C++ binary**. A naive port to
`protwis_django_docker` that just `subprocess`-es Foldseek inside the
Django container would *regress* on that property.

The proposed `protwis_django_docker`-era design keeps the sandbox by
turning Foldseek into a **sibling Compose service** with a small HTTP
interface, sitting next to `app`, `db` and `adminer`. This removes the
`docker`-in-Django coupling, removes the host-path-translation problem,
and lines up cleanly with how the rest of the stack is composed.

---

## 1. What Foldseek does in GPCRdb

[Foldseek](https://github.com/steineggerlab/foldseek) is a fast structural
search tool (the structural analogue of BLAST). The
`structure_similarity_search` view lets a user upload a single GPCR
structure (`.pdb`, `.cif`, or `.mmcif`), pick one or more reference sets
(experimental / homology-refined / AlphaFold), pick an alignment method
(3Di, TM-align, 3Di+AA), and returns the most similar structures from the
chosen set(s).

The actual command run on every request is:

```
foldseek easy-search <user_input> <db_dir> <result.txt> <tmp> \
        --alignment-type <0|1|2> \
        --format-output "query,target,ttmscore,lddt,evalue"
```

`<db_dir>` is a directory of annotated PDB files — `easy-search` builds
the index on the fly.

---

## 2. Today: how Foldseek runs in production

Three pieces collaborate in the current production stack.

### 2.1 The data: trimmed PDB directories

The "Foldseek DBs" are not Foldseek's own binary index format; they are
just **directories of pre-processed PDB files** that `easy-search`
consumes directly.

They are produced by a Django management command, `foldseek_db` (in
[`structure/management/commands/foldseek_db.py`](https://github.com/protwis/protwis/blob/dev_build/structure/management/commands/foldseek_db.py)
on the `dev_build` branch), which:

- queries the DB for experimental, homology-refined, and AlphaFold
  structures;
- assigns generic numbers using BioPython;
- filters residues by CA-atom B-factor (catching ordered residues and
  bulges);
- writes one annotated `.pdb` file per structure into

      {DATA_DIR}/structure_data/raw_foldseek_db_trim/
      {DATA_DIR}/structure_data/ref_foldseek_db_trim/
      {DATA_DIR}/structure_data/af_foldseek_db_trim/

Important: **`foldseek_db.py` does not invoke Foldseek itself.** Its only
heavy dependency is BioPython. The Foldseek binary is needed only at
query time, inside the view.

### 2.2 The Foldseek image: `foldseek_docker`

Provided out-of-band on the Gloriam lab OneDrive
(`1.Databases/GPCRdb/Dev/foldseek/foldseek_docker/`) — *not* in either
`protwis` or `protwis_django_docker`. It is three files:

```dockerfile
# Dockerfile
FROM continuumio/miniconda3:latest
RUN conda install -c conda-forge -c bioconda foldseek -y && conda clean --all -y
WORKDIR /app
CMD ["foldseek"]
```

```bash
# dockerized_foldseek.sh
docker build -t foldseek .
```

Plus a `ReadMe.txt` whose setup instructions are conda-flavoured
(`conda activate gpcrdb`, `pip install docker==24.0.2`, copy the DB
directories into `structure_data/`).

The result is an image tagged `foldseek:latest` on the production host.

### 2.3 The invocation: `docker` SDK from inside Django

The Django view that drives the feature is `StructureBlastView` in
[`structure/views.py`](https://github.com/protwis/protwis/blob/dev_build/structure/views.py)
(`run_foldseek`, lines ~4662–4753 on `dev_build`). The control flow on
each POST:

1. A `docker.from_env()` client is created — it talks to the host's
   Docker daemon over the default socket.
2. A per-request temporary directory is created with `input/` and
   `output/` subdirectories. The uploaded structure is copied into
   `input/`.
3. `client.containers.run('foldseek:latest', ...)` launches an
   **ephemeral, detached** sibling container with the following mounts:

   | Host path                                              | Container path        | Mode |
   |--------------------------------------------------------|-----------------------|------|
   | `tmp/.../input/`                                       | `/input`              | `ro` |
   | `{DATA_DIR}/structure_data/af_foldseek_db_trim/`       | `/af_foldseek_db`     | `ro` |
   | `{DATA_DIR}/structure_data/ref_foldseek_db_trim/`      | `/ref_foldseek_db`    | `ro` |
   | `{DATA_DIR}/structure_data/raw_foldseek_db_trim/`      | `/raw_foldseek_db`    | `ro` |
   | `tmp/.../output/`                                      | `/output`             | `rw` |

4. The container's command is a short shell pipeline:

   ```
   sh -c 'mkdir -p /db
          && find /<selected_db> -maxdepth 1 -exec ln -s {} /db/ \;   (per selected DB)
          && foldseek easy-search /input/<file> /db /output/result.txt /tmp \
                --alignment-type <N> --format-output "query,target,ttmscore,lddt,evalue"'
   ```

   The symlink trick lets the view combine multiple selected reference
   sets into a single search.

5. `container.wait()` blocks until Foldseek exits. The view reads logs
   for status, reads `result.txt` from `output/`, copies it to a
   long-lived temp path, and returns it to the response renderer.

6. A `finally` block removes the container by name, even on exception.

### 2.4 What the design solves

There are four plausible motivations behind running Foldseek as a
sibling container rather than in-process. Three of them are still
relevant when we re-platform; one is not.

1. **Conda dependency hygiene.** Foldseek's bioconda package pulls a
   stack of C++ dependencies. Keeping it out of the long-lived `gpcrdb`
   conda environment — or away from a frozen production environment —
   is easier with a separate image. The conda-shaped `ReadMe.txt` makes
   it likely that this was the *conscious* motivation.

2. **Process / crash isolation.** Foldseek is a complex C++ binary.
   Crashes, leaks, and runaway memory inside it don't reach the
   long-running Django process. The view's careful container lifecycle
   handling (`wait` → check `StatusCode` → read logs → `finally` remove)
   shows the author was thinking about lifecycle.

3. **Filesystem sandbox around an untrusted upload.** Every mount is
   explicitly `'mode': 'ro'` except the dedicated output directory. The
   Foldseek container has its own filesystem and process namespace; it
   cannot see Django's source, its environment variables (which include
   `POSTGRES_PASSWORD` and `SECRET_KEY`), or any other socket. Because
   the input is a user upload being parsed by a C++ binary — a category
   of code historically rich in CVEs — this isolation is a real
   defence-in-depth boundary, regardless of whether the author chose it
   for that reason.

4. **Cross-platform consistency.** Running Foldseek through Docker hides
   any conda-resolution differences between operator machines.

A useful, honest qualification: **the sandbox is partial.** There is no
`mem_limit`, no `cpu_quota`, no dropped capabilities, no non-root
`USER`. The Foldseek image is `FROM continuumio/miniconda3` and runs as
root. So we should not over-attribute security intent to the original
author. What the design *does* deliver, intended or not, is filesystem
isolation, ephemerality, and namespace separation from Django — and that
is what we will keep.

---

## 3. What changes under `protwis_django_docker`

### 3.1 The new context

In `protwis_django_docker`, Django no longer runs directly on a conda
host. It runs inside the `app` container. That single change invalidates
the simplest two ways of preserving the current architecture.

### 3.2 Why "just `subprocess`-ing Foldseek inside the `app` container"
is wrong

It is tempting: add Foldseek to the runtime image alongside
`ncbi-blast+`, `clustalo`, `dssp`, `phylip`; rewrite `run_foldseek` as a
`subprocess.run([...])`; delete ~50 lines of Docker SDK plumbing.
Mechanically clean.

But this **regresses on the filesystem sandbox**. Foldseek would run as
the Django user, in Django's filesystem namespace, with Django's
environment. A vulnerability in Foldseek's structural-file parser
triggered by a malicious upload would no longer compromise only an
ephemeral sandbox container — it would compromise the `app` container
directly, exposing:

- `SECRET_KEY` (Django session/cookie forgery, potential admin
  impersonation);
- `POSTGRES_PASSWORD` and reachability to the `db` service;
- the bind-mounted `protwis` source tree (in dev) or the runtime image
  contents (in production);
- the bind-mounted `gpcrdb_data` tree, including the read-write portions
  used by build commands.

For a publicly accessible scientific tool that accepts arbitrary user
uploads, that is not an equivalent change. It is a security regression
that should be a conscious decision, not an accident of refactoring.

### 3.3 Why "mount `/var/run/docker.sock` and keep the SDK" doesn't
work either

The `volumes={...}` dict passed to `client.containers.run()` is
interpreted by the **host's** Docker daemon. Its keys must be paths the
host can resolve. In today's production they are, because Django runs on
the host. In a containerised Django:

- `tempfile.mkdtemp()` returns a path inside the `app` container's
  filesystem — there is no such path on the host.
- `settings.DATA_DIR` evaluates to `/app/data/protwis/gpcr` (from
  `settings_local_docker.py` and `PROTWIS_DATA_DIR`) — there is no such
  path on the host either.

The Foldseek sibling container would therefore receive empty or wrong
mounts and the feature would silently fail. Making it work requires
forcing host and in-container paths to coincide (mounting the data tree
at identical absolute paths on both sides and forcing `tempfile` into a
shared bind-mount). That is fragile, leaks host filesystem layout into
the compose configuration, and still leaves two serious problems:

- giving any container access to `/var/run/docker.sock` is effectively
  granting it root on the host;
- the `foldseek:latest` image must be pre-built on the host out of band,
  which is exactly the kind of "magic step" `protwis_django_docker` was
  meant to eliminate.

### 3.4 Re-evaluating the four motivations

| # | Motivation                | Still relevant? | How it is preserved in the new design |
|---|---------------------------|-----------------|---------------------------------------|
| 1 | Conda dep hygiene         | **No**          | The stack already has no conda. Foldseek becomes "another bioinformatics CLI", on the same footing as `ncbi-blast+`/`clustalo`. |
| 2 | Process / crash isolation | Yes             | Foldseek runs in a separate process — and in fact in a separate container — from Django. |
| 3 | Filesystem sandbox        | **Yes — crucial** | A separate Compose service with its own filesystem namespace, no DB credentials in its environment, and `ro` mounts of only the data it needs. |
| 4 | Cross-platform            | Yes (free)      | Falls out of containerisation itself. |

Motivation #3 is the one that drives the design. Motivation #1, the most
likely *conscious* reason behind the original choice, is the only one we
can safely drop.

---

## 4. The proposed solution: Foldseek as a Compose sibling service

### 4.1 Architecture

```
                         compose network
   ┌──────────┐          ┌──────────────────────┐
   │  client  │──HTTPS──▶│  app (Django)        │
   └──────────┘          │  - runserver/gunicorn│
                         └─────┬────────────────┘
                               │ HTTP (compose-internal only)
                               ▼
                         ┌──────────────────────┐      ┌──────────────────┐
                         │  foldseek (service)  │──ro─▶│ gpcrdb_data/     │
                         │  - FastAPI wrapper   │      │   structure_data │
                         │  - foldseek binary   │      └──────────────────┘
                         └──────────────────────┘
                               ▲
                               │ (no DB access, no source mount,
                               │  no secrets, no docker socket)
                               │
                         ┌──────────────────────┐
                         │  db (Postgres+RDKit) │  (unchanged)
                         └──────────────────────┘
```

Key points:

- Foldseek lives in its own image, with its own minimum set of
  dependencies, in its own filesystem and process namespace.
- The only thing the Foldseek service mounts from the data tree is the
  `structure_data/` subdirectory, read-only.
- The Foldseek service does **not** have the DB credentials, does **not**
  have `SECRET_KEY`, does **not** see the `protwis` source tree, does
  **not** have a Docker socket.
- The service is reachable only on the Compose network. No host port is
  published.

### 4.2 The Foldseek service image (`foldseek/Dockerfile`)

Sketch:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm

ARG TARGETARCH
ARG FOLDSEEK_VERSION=<pin a release tag>

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && case "$TARGETARCH" in \
         amd64) FS_ARCHIVE=foldseek-linux-avx2.tar.gz ;; \
         arm64) FS_ARCHIVE=foldseek-linux-arm64.tar.gz ;; \
         *) echo "unsupported arch: $TARGETARCH" >&2 && exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/foldseek.tgz \
       "https://github.com/steineggerlab/foldseek/releases/download/${FOLDSEEK_VERSION}/${FS_ARCHIVE}" \
    && tar -C /opt -xzf /tmp/foldseek.tgz \
    && ln -s /opt/foldseek/bin/foldseek /usr/local/bin/foldseek \
    && rm /tmp/foldseek.tgz \
    && apt-get purge -y curl && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
        'fastapi==<pin>' 'uvicorn[standard]==<pin>' python-multipart

RUN useradd -r -u 1000 foldseek
USER foldseek

WORKDIR /app
COPY --chown=foldseek:foldseek server.py /app/server.py

EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
```

Notes:

- **Multi-arch**, matching how `protwis_django_docker:latest` is
  published. Foldseek ships per-arch static binaries on GitHub Releases.
- **Non-root** by default. Easy to do here — there is no legacy reason
  for root.
- **No conda.** Same uv-era hygiene as the main image.

### 4.3 The HTTP interface (`foldseek/server.py`)

A single endpoint, ~60 lines. Sketch:

```python
"""Foldseek HTTP service for GPCRdb structure similarity search."""
import os, subprocess, tempfile
from pathlib import Path
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse

app = FastAPI()

DB_ROOT = Path(os.environ.get("FOLDSEEK_DB_ROOT", "/data/structure_data"))
DB_NAMES = {"af": "af_foldseek_db_trim",
            "ref": "ref_foldseek_db_trim",
            "raw": "raw_foldseek_db_trim"}
ALLOWED_EXT = {".pdb", ".cif", ".mmcif"}
MAX_BYTES = 5 * 1024 * 1024
TIMEOUT_S = 300

@app.post("/search", response_class=PlainTextResponse)
async def search(
    input_file: UploadFile = File(...),
    alignment_type: int = Form(...),
    structure_types: str = Form(...),  # comma-separated subset of {af,ref,raw}
):
    ext = Path(input_file.filename or "").suffix.lower()
    if ext not in ALLOWED_EXT:
        raise HTTPException(400, f"unsupported extension {ext!r}")
    if alignment_type not in (0, 1, 2):
        raise HTTPException(400, "alignment_type must be 0, 1, or 2")
    sts = [s.strip() for s in structure_types.split(",") if s.strip()]
    if not sts or not set(sts).issubset(DB_NAMES):
        raise HTTPException(400, f"structure_types must be subset of {sorted(DB_NAMES)}")

    data = await input_file.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "input file too large")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        in_path = tmp / f"input{ext}"
        in_path.write_bytes(data)
        db_dir = tmp / "db"; db_dir.mkdir()
        for st in sts:
            src = DB_ROOT / DB_NAMES[st]
            if not src.is_dir():
                raise HTTPException(500, f"DB not found: {DB_NAMES[st]}")
            for p in src.iterdir():
                (db_dir / p.name).symlink_to(p)

        out_path = tmp / "result.txt"
        proc = subprocess.run(
            ["foldseek", "easy-search", str(in_path), str(db_dir),
             str(out_path), str(tmp / "fs_tmp"),
             "--alignment-type", str(alignment_type),
             "--format-output", "query,target,ttmscore,lddt,evalue"],
            capture_output=True, text=True, timeout=TIMEOUT_S,
        )
        if proc.returncode != 0:
            raise HTTPException(500, f"foldseek failed: {proc.stderr[-2000:]}")
        if not out_path.exists() or out_path.stat().st_size == 0:
            raise HTTPException(204, "")  # no hits / no parseable structure
        return out_path.read_text()
```

The shell pipeline that lives inside the current production container
(`mkdir -p /db && find ... -exec ln -s ... && foldseek easy-search ...`)
collapses naturally into Python: the symlink loop is explicit, the
`subprocess.run` replaces the SDK's `containers.run` + `wait` + `logs` +
`finally`. The Foldseek invocation arguments are unchanged.

### 4.4 The Django side: `run_foldseek` rewrite

The view becomes a thin HTTP client. Sketch:

```python
def run_foldseek(self, temp_file_path, fdb, alignment_type):
    """Execute the Foldseek search via the sibling foldseek service."""
    if not self.validate_structure_file(temp_file_path):
        return None, "Invalid structure file: ..."

    short = {"af_foldseek_db": "af",
             "ref_foldseek_db": "ref",
             "raw_foldseek_db": "raw"}
    structure_types = ",".join(short[name] for name in self.structure_type)

    try:
        with open(temp_file_path, "rb") as f:
            r = requests.post(
                f"{settings.FOLDSEEK_SERVICE_URL}/search",
                files={"input_file": (os.path.basename(temp_file_path), f)},
                data={"alignment_type": alignment_type,
                      "structure_types": structure_types},
                timeout=getattr(settings, "FOLDSEEK_TIMEOUT", 300),
            )
    except requests.RequestException as e:
        return None, f"Could not reach foldseek service: {e}"

    if r.status_code == 204:
        return None, "No structures found in the input file"
    if r.status_code != 200:
        return None, f"Foldseek execution failed: {r.text[-2000:]}"

    final_path = tempfile.mktemp(suffix=".txt", prefix="foldseek_result_")
    self.cleanup_resources.append(final_path)
    with open(final_path, "w") as f:
        f.write(r.text)
    return final_path, None
```

That replaces roughly 80 lines of Docker SDK plumbing with about 25
lines of HTTP-client code. `import docker` and `import uuid` (for the
container-name UUID) go away from this code path. The `fdb` parameter is
no longer consumed by `run_foldseek` itself — the Foldseek service knows
its DB layout — but it can stay in the signature for minimal diff and so
`parse_and_enhance_results` can still use it if needed.

### 4.5 `docker-compose.yml` addition

```yaml
  foldseek:
    build:
      context: ./foldseek
    image: ghcr.io/protwis/protwis_foldseek:latest
    container_name: ${COMPOSE_PROJECT_NAME:-gpcrdb}-foldseek
    restart: unless-stopped
    environment:
      - FOLDSEEK_DB_ROOT=/data/structure_data
    volumes:
      - ${PROTWIS_GPCRDB_DATA:-../gpcrdb_data}/structure_data:/data/structure_data:ro
    # Internal only. Reachable as http://foldseek:8000 on the compose network.
    # Resource caps belong here so a heavy query can't starve the Django app.
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: '2.0'
```

The `app` service gains exactly one new environment variable:

```yaml
      - FOLDSEEK_SERVICE_URL=http://foldseek:8000
```

`settings_local_docker.py` (in `protwis/dev_build`) gains the matching
line:

```python
FOLDSEEK_SERVICE_URL = os.environ.get("FOLDSEEK_SERVICE_URL", "http://foldseek:8000")
```

That is the entire glue.

### 4.6 Properties: what is preserved, what is improved

| Property                                              | Today | Naive `subprocess` port | Proposed (sibling service) |
|-------------------------------------------------------|:-----:|:----------------------:|:--------------------------:|
| Foldseek runs in its own filesystem namespace         |  ✅   |          ❌            |             ✅             |
| No DB credentials visible to Foldseek                 |  ✅   |          ❌            |             ✅             |
| No Django `SECRET_KEY` visible to Foldseek            |  ✅   |          ❌            |             ✅             |
| Per-request ephemerality                              |  ✅   |          ✅            |             ✅             |
| Read-only mounts for inputs and DBs                   |  ✅   |          ❌            |             ✅             |
| Process / crash isolation from Django                 |  ✅   |          ⚠️            |             ✅             |
| Resource limits (mem, cpu)                            |  ❌   |          ❌            |          ✅ (compose)      |
| No `/var/run/docker.sock` mount                       |  ✅*  |          ✅            |             ✅             |
| No host-path translation                              |  ✅*  |          ✅            |             ✅             |
| Foldseek image lives in a tracked repository          |  ❌   |          ✅            |             ✅             |
| Container orchestration done by Compose, not Django   |  ❌   |          ✅            |             ✅             |

\* The current production stack avoids both because Django runs on the
host, not in a container. Once Django moves into a container, these
become real risks under the SDK-based approach.

The proposed design is the *only* one that keeps every ✅ from today,
fixes the two ❌s in the bottom-right, and avoids the regressions of a
naive port.

---

## 5. Migration plan

This is a sketch, not a commitment. Each step is independent and
testable.

1. **`protwis_django_docker`: add the `foldseek/` directory.**
   - `foldseek/Dockerfile` (per §4.2)
   - `foldseek/server.py` (per §4.3)
   - `foldseek/.dockerignore`
   - smoke step in `ci.yml` that builds the new image and curls
     `/search` against a tiny fixture.

2. **`protwis_django_docker`: extend `docker-compose.yml`** (per §4.5)
   with the `foldseek` service and the new `FOLDSEEK_SERVICE_URL` env
   var on `app`.

3. **`protwis_django_docker`: extend the publish workflows.** Add a
   multi-arch publish job for `protwis_foldseek:latest` modelled on
   `docker-publish.yml`. The compatibility-matrix workflow does *not*
   need to grow a Foldseek axis — Foldseek's deps don't move with
   Python/Django/RDKit.

4. **`protwis` (`dev_build` branch): rewrite `run_foldseek`** in
   `structure/views.py` to be an HTTP client (per §4.4). Drop
   `import docker` from that file. Add `FOLDSEEK_SERVICE_URL` to
   `settings_local_docker.py` / `settings_production_docker.py`. This
   step is the one tension with the "no invasive changes to protwis"
   principle in the main README — but the change is localised to one
   method and replaces 80 lines with 25.

5. **Documentation:** `docs/onboarding.md` gets one paragraph in §1
   explaining the four-service stack (`app` + `db` + `adminer` +
   `foldseek`).

6. **Decommission the old image:** once the new path is verified end to
   end against production data, the `foldseek_docker/` directory on the
   shared drive becomes a historical artefact. `pip install docker` can
   eventually be dropped from `protwis`'s `pyproject.toml` if no other
   code path uses it.

Each of steps 1–5 is independently mergeable; the feature only switches
over at step 4.

---

## 6. Open questions

These should be answered before implementation, not in this document.

- **Foldseek version pin.** Pick a release tag (and decide whether to
  re-pin on the same cadence as `docker-publish.yml`, or only when the
  upstream `protwis` code starts depending on a newer feature).
- **Resource limits.** `4G` / `2 CPUs` is a placeholder. The right
  numbers depend on the largest expected query and the production
  host's headroom.
- **File-size limit.** `5 MB` is a placeholder. A PDB with a large
  multi-chain assembly can plausibly exceed that.
- **Timeout.** 300 s is a placeholder. Some `--alignment-type 1`
  (TM-align) searches may take longer.
- **Concurrency.** Uvicorn defaults to one worker; a single Foldseek
  process is multi-threaded internally. Whether to allow multiple
  concurrent searches depends on the host. Add `--workers N` to the
  `CMD` once decided.
- **Authentication on the Foldseek endpoint.** Reachable only on the
  Compose network today, so unauthenticated is acceptable. If the
  service is ever made reachable from outside the stack, a shared
  secret in headers would be the lightest addition.
- **Observability.** Decide whether the Foldseek service should emit
  structured logs / Prometheus metrics, or whether default Uvicorn logs
  are enough.
- **Path layout for the data bind-mount.** §4.5 mounts only
  `gpcrdb_data/structure_data`. Confirm that no other Foldseek-adjacent
  files live elsewhere in the tree.

---

## 7. Out of scope

This document is about Foldseek only. It does **not** address:

- The broader "is `protwis_django_docker` a viable production stack?"
  question — gunicorn vs `runserver`, static-file serving, reverse
  proxy, TLS termination, log shipping, and so on. Those belong in a
  separate `production.md`. Foldseek is one ingredient.
- Changes to `foldseek_db.py`. That command is fine as-is and runs in
  the existing `app` image (BioPython only, no Foldseek needed).
- Other Foldseek-related GPCRdb features that may emerge later.
