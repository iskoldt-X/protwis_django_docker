# Compatibility Matrix

_Last run: 2026-06-12 17:04 UTC_ · [workflow run](https://github.com/protwis/protwis_django_docker/actions/runs/27428613876)

**Summary:** 26 / 36 green (amd64+arm64) · 0 partial (single arch) · 10 red (lock) · 0 red (build).

Green cells publish a multi-arch manifest under the un-suffixed tag; partial cells publish only the per-arch tag shown. The tag in each cell is what you `docker pull`.

---

## Python 3.8

| Django \ RDKit | 2023.09 | 2024.09 | 2025.09 | 2026.03 |
|---|---|---|---|---|
| **3.2** | [`matrix-py38-dj32-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | ❌ lock | ❌ lock | ❌ lock |
| **4.2** | [`matrix-py38-dj42-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | ❌ lock | ❌ lock | ❌ lock |
| **5.2** | ❌ lock | ❌ lock | ❌ lock | ❌ lock |

## Python 3.11

| Django \ RDKit | 2023.09 | 2024.09 | 2025.09 | 2026.03 |
|---|---|---|---|---|
| **3.2** | [`matrix-py311-dj32-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj32-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj32-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj32-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |
| **4.2** | [`matrix-py311-dj42-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj42-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj42-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj42-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |
| **5.2** | [`matrix-py311-dj52-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj52-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj52-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py311-dj52-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |

## Python 3.12

| Django \ RDKit | 2023.09 | 2024.09 | 2025.09 | 2026.03 |
|---|---|---|---|---|
| **3.2** | [`matrix-py312-dj32-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj32-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj32-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj32-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |
| **4.2** | [`matrix-py312-dj42-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj42-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj42-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj42-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |
| **5.2** | [`matrix-py312-dj52-rdk202309`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj52-rdk202409`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj52-rdk202509`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ | [`matrix-py312-dj52-rdk202603`](https://github.com/protwis/protwis_django_docker/pkgs/container/protwis_django_docker) ✅ |

---

## Status legend

- **✅** — both amd64 and arm64 built; the tag is a multi-arch manifest.
- **⚠️ amd64 only** / **⚠️ arm64 only** — the other arch failed to build; only the per-arch tag shown is published (no manifest list).
- **❌ lock** — `uv lock` did not resolve.
- **❌ build** — lock resolved but `docker build` failed on both arches (typically a missing system library or native-extension break).
- **—** — no result (cell skipped or workflow interrupted).

## Reproduce a cell locally

```bash
# Example: py3.11 / dj4.2 / rdk2024.09 on your native arch
PY_MIN=3.11 PY_MAX=3.12 \
DJANGO_MAJOR=4.2 DJANGO_NEXT=5.0 \
RDKIT_MAJOR=2024.09 RDKIT_NEXT=2024.10 \
envsubst < pyproject.matrix.toml.tmpl > pyproject.toml
uv lock                                                 # gate 1
docker build --build-arg PYTHON_VERSION=3.11 -t probe . # gate 2
```

