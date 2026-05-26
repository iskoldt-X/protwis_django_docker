# GPCRdb Docker on Windows

This is a Windows-specific companion to [`onboarding.md`](onboarding.md). The main onboarding doc was written for Linux/macOS shells; this one covers the gotchas you hit when running the stack from a native Windows shell (PowerShell or Git Bash) with Docker Desktop.

> **Scope.** This guide is for **Docker Desktop on Windows**, which uses WSL2 only as its container backend. All commands here are run from a regular Windows shell (PowerShell or Git Bash), *not* from inside a WSL2 Ubuntu terminal. If you do want to run everything from inside a WSL2 distro, follow [`onboarding.md`](onboarding.md) verbatim — it already works there.

---

## 1. Choose a shell

You have two realistic options on Windows. Pick one and stick with it for a session:

| Shell | Works for everything? | Notes |
|---|---|---|
| **Git Bash** (Git for Windows) | Yes | Bash-compatible. All commands in `onboarding.md` work unchanged. Ships `curl`, `gunzip`, `find`, `file`. The path of least resistance. |
| **PowerShell 5.1 / 7** | Mostly | Needs command translation, and one step (the gzipped dump pipe) is awkward — see §6. |

The rest of this doc assumes PowerShell unless noted. Git Bash users can read along; the bash equivalents are exactly what's in `onboarding.md`.

## 2. Prerequisites (Windows)

- **Docker Desktop for Windows** with the **WSL2 backend enabled** (default for new installs). Verify with `docker info` — the server should be running.
- **Git for Windows** (ships Git Bash and `curl.exe`).
- **~30 GB free disk space.** The Postgres volume lives in the Docker Desktop WSL2 VHD under `C:\Users\<you>\AppData\Local\Docker\wsl\`. Make sure that drive has room.
- Optional but useful: enable **Windows long paths** so Git never trips on deep node-style paths:
  ```powershell
  git config --system core.longpaths true
  ```

## 3. Before you clone: line endings (important)

Git for Windows ships with `core.autocrlf=true`, which rewrites LF → CRLF on checkout. Python tolerates CRLF, but any **shell scripts** in the `protwis` source (e.g. `build/resource_preprocessing/*.sh`) will be checked out with CRLF and then fail inside the Linux container with cryptic errors like `bash: bad interpreter: /bin/bash^M`.

Set this **before cloning**:
```powershell
git config --global core.autocrlf input
```

This preserves LF on checkout and only normalises commits going the other way. If you've already cloned with `autocrlf=true`, you can re-normalise without re-cloning:
```powershell
cd C:\path\to\workspace\protwis
git rm --cached -r .
git reset --hard
```

You can verify a file's line endings any time with Git Bash's `file`:
```bash
file build/resource_preprocessing/generate_entrezgeneid_lookup.sh
# Want: "ASCII text" (LF)
# Bad:  "ASCII text, with CRLF line terminators"
```

## 4. First-time setup, Windows edition

The `onboarding.md` bash commands, translated to PowerShell.

### 4.1 Clone the three repos side-by-side

Pick a workspace directory and clone the three repos as siblings. You don't need a `~/GitHub` convention — anywhere short and ASCII works (avoid OneDrive-synced folders, which can confuse bind mounts):

```powershell
$workspace = "$env:USERPROFILE\Documents\protwis_docker"
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
Set-Location $workspace

git clone -b dev_build https://github.com/protwis/protwis
git clone https://github.com/protwis/gpcrdb_data
git clone https://github.com/iskoldt-x/protwis_django_docker
```

> **Why the `dev_build` branch?** Same reason as the main doc — it ships the `settings_*_docker.py` files the container expects. Cloning `master` will crash the app on startup.

### 4.2 Configure `.env`

```powershell
Set-Location protwis_django_docker
Copy-Item .env.example .env
```

The defaults (`PROTWIS_SRC=../protwis`, `PROTWIS_GPCRDB_DATA=../gpcrdb_data`) match the side-by-side layout above — no edits needed.

### 4.3 Bring up the stack

```powershell
docker compose up -d
docker compose ps
```

Wait until `gpcrdb-db` shows `(healthy)`. On first run, Docker pulls ~2 GB of images, so give it a few minutes.

## 5. Switching the protwis source to your own fork

If you maintain your own `protwis` fork and want to work on your branches inside this stack, repoint the `protwis` subfolder's `origin` at your fork (keeping the canonical upstream as `upstream` so you can still pull from it).

```powershell
cd C:\Users\<you>\Documents\protwis_docker\protwis
git remote rename origin upstream
git remote add origin https://github.com/<YOUR_GH_USERNAME>/protwis.git
git remote -v   # sanity: origin = your fork, upstream = protwis/protwis
git fetch origin
git branch -r   # see what's on your fork
git checkout -b <your-branch> origin/<your-branch>
```

From now on, `git pull` / `git push` defaults to your fork; `git fetch upstream` is how you pick up new commits from `protwis/protwis`.

### Gotcha: your branch may not carry `settings_local_docker.py`

The app container starts with `DJANGO_SETTINGS_MODULE=protwis.settings_local_docker`. That file lives only on upstream's `dev_build` branch and anything forked from it. If your work branch was forked from `master` or an older base, the app crashes on startup with:

```
ModuleNotFoundError: No module named 'protwis.settings_local_docker'
```

Check whether your branch has it:
```powershell
git ls-files protwis/settings_local_docker.py
```
Empty output = file is missing. Pick one fix.

**Option A — Cherry-pick just the two docker settings files** (no other `dev_build` history):
```powershell
git fetch upstream
git checkout upstream/dev_build -- protwis/settings_local_docker.py protwis/settings_production_docker.py
git add protwis/settings_local_docker.py protwis/settings_production_docker.py
git commit -m "Add docker-stack settings files from dev_build"
```

**Option B — Merge `upstream/dev_build` into your branch** (also picks up any other `dev_build` updates):
```powershell
git fetch upstream
git merge upstream/dev_build
```
Resolve any conflicts in VS Code's merge editor, then commit the merge.

**Then restart the app container so it sees the new files:**
```powershell
cd ..\protwis_django_docker
docker compose restart app
docker compose logs -f app    # wait for "Starting development server at http://0.0.0.0:8000/"
```

## 6. Loading the database dump (the PowerShell trap)

This is the one step where PowerShell genuinely gets in your way.

The upstream command is:
```bash
gunzip -c ~/protwis.sql.gz | docker exec -i gpcrdb-db psql -U protwis -d protwis -q -1
```

That works **as-is in Git Bash**. In **native PowerShell** the binary pipe is unreliable: PowerShell 5.1 treats pipeline data as text and re-encodes it, which corrupts the gzip byte stream. PowerShell 7 is better but still inconsistent across versions.

Pick one of these three options.

### Option A — Use Git Bash for this one command (simplest)

Git Bash ships with Git for Windows. Open it, then:
```bash
curl -L https://files.gpcrdb.org/protwis_sp.sql.gz -o ~/protwis.sql.gz
gunzip -c ~/protwis.sql.gz | docker exec -i gpcrdb-db psql -U protwis -d protwis -q -1
```

You can drop straight back into PowerShell after.

### Option B — Decompress to disk first, then pipe the SQL file

This works in PowerShell, but the uncompressed dump is ~26 GB on disk temporarily:

```powershell
# Download (use curl.exe, NOT the PowerShell `curl` alias — see §7)
curl.exe -L https://files.gpcrdb.org/protwis_sp.sql.gz -o "$env:USERPROFILE\protwis.sql.gz"

# Decompress via 7-Zip if installed
& "C:\Program Files\7-Zip\7z.exe" e "$env:USERPROFILE\protwis.sql.gz" -o"$env:USERPROFILE" -y

# Or decompress via Python (no extra installs needed if you have Python on PATH)
python -c "import gzip,shutil; shutil.copyfileobj(gzip.open(r'$env:USERPROFILE\protwis.sql.gz','rb'), open(r'$env:USERPROFILE\protwis.sql','wb'))"

# Load — note we use Get-Content -Raw and pipe text, which is safe because the .sql is text
Get-Content "$env:USERPROFILE\protwis.sql" -Raw | docker exec -i gpcrdb-db psql -U protwis -d protwis -q -1

# Cleanup
Remove-Item "$env:USERPROFILE\protwis.sql"
```

### Option C — Copy the gz into the container, decompress + load there

Keeps the host clean:
```powershell
docker cp "$env:USERPROFILE\protwis.sql.gz" gpcrdb-db:/tmp/protwis.sql.gz
docker exec gpcrdb-db bash -c "gunzip -c /tmp/protwis.sql.gz | psql -U protwis -d protwis -q -1 && rm /tmp/protwis.sql.gz"
```

All three take **10–25 minutes** on Windows. Don't interrupt — the load runs as a single transaction (`-1`), and Postgres looks empty from outside until the very last second.

## 7. PowerShell command translations cheat sheet

| Bash / `onboarding.md` | PowerShell equivalent |
|---|---|
| `cd ~/GitHub` | `Set-Location "$env:USERPROFILE\GitHub"` |
| `cp .env.example .env` | `Copy-Item .env.example .env` |
| `ls -la` | `Get-ChildItem -Force` |
| `cat file` | `Get-Content file` |
| `curl -L URL -o path` | `curl.exe -L URL -o path` ⚠️ Use `curl.exe`, not `curl` (which aliases to `Invoke-WebRequest` in PowerShell and has different flags). |
| `rm -rf dir` | `Remove-Item -Recurse -Force dir` |
| `lsof -i :8000` (find process on port) | `Get-NetTCPConnection -LocalPort 8000` |
| Environment variable `$HOME` | `$env:USERPROFILE` (or `$HOME`, which PowerShell also defines) |
| `export FOO=bar` | `$env:FOO = "bar"` |

`docker`, `docker compose`, and the inside-container `python manage.py ...` parts of every command are **identical** across both shells.

## 8. Daily-use commands (Windows-friendly)

These work unchanged in PowerShell and Git Bash. Run from inside `protwis_django_docker\`:

```powershell
docker compose up -d                                    # Start
docker compose down                                     # Stop (keeps DB volume)
docker compose logs -f app                              # Tail Django logs (Ctrl+C to exit)
docker compose exec app bash                            # Shell into the app container
docker compose exec app python manage.py <command>      # Any Django command
```

For the detached pattern used by long builds:
```powershell
docker compose exec -T -d app python manage.py build_homology_models
docker compose logs -f app
```

The `-T` (no TTY allocation) is **important in PowerShell** — otherwise you can get encoding glitches when Docker negotiates a Windows terminal.

## 9. Tested commands on Windows + Docker Desktop

To sanity-check the five command categories from `onboarding.md` §8, the following were run on a fresh Windows install with Docker Desktop (WSL2 backend):

| Category | Command | Result |
|---|---|---|
| 1. Built-in Django | `migrate` (after dump load) | Applied 4 schema-drift migrations in ~3s. Re-running prints `No migrations to apply.` |
| 2. Read-only diagnostic | `shell -c "from protein.models import Protein; print(Protein.objects.count())"` | Returned `46094` instantly. |
| 3. Small data update | `build_links` | Completed in **~3m 44s**. (Linux/Mac reference: ~53s.) |
| 4. Long build pipeline | *not run* | Doc reference: hours. Run detached with `-T -d`. |
| 5. Modeller-requiring | `build_complex_models` | Crashed at import as expected: `ModuleNotFoundError: No module named 'modeller'`. |

**The ~4× slowdown on `build_links`** is the most useful number here. It reflects the Docker Desktop bind-mount cost between Windows host paths and the Linux container backend — every Python import in the bind-mounted `/app/src` traverses the 9P/virtiofs boundary. This is just how Docker Desktop on Windows works with host-path bind mounts; there's no setting that makes it native-speed. For interactive editing and shell-style commands it's fine. For long build pipelines (category 4), expect noticeably longer wall times than the figures quoted in `onboarding.md` — plan accordingly.

## 10. Windows-specific troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bash: ./script.sh: /bin/bash^M: bad interpreter` | Shell script in bind-mounted source has CRLF line endings from Git autocrlf. | See §3. Set `core.autocrlf=input`, re-checkout, or convert the file with `dos2unix`. |
| `Invoke-WebRequest : A parameter cannot be found that matches parameter name 'o'` | You called `curl` (PowerShell alias for `Invoke-WebRequest`) instead of `curl.exe`. | Use `curl.exe -L URL -o path`. |
| `ModuleNotFoundError: No module named 'protwis.settings_local_docker'` | The branch checked out in `protwis/` doesn't carry the docker settings file (forked off `master` or an older base). | See §5. Cherry-pick the two settings files from `upstream/dev_build`, or merge `upstream/dev_build` in. |
| `psql: FATAL: role "<your-windows-username>" does not exist` | You ran `psql` directly on the Windows host, hitting a different PG. | All `psql` should go via `docker exec -i gpcrdb-db psql -U protwis -d protwis ...`. |
| Dump load corrupts / errors halfway in PowerShell | PowerShell binary pipe re-encodes the gzipped stream. | Use Option A, B, or C from §6. |
| `Error response from daemon: Ports are not available: ... bind: An attempt was made to access a socket in a way forbidden` | A reserved Windows port range overlaps with 5432/8000/8888 (the Hyper-V "excluded port range"). | Run `netsh interface ipv4 show excludedportrange protocol=tcp` to check; either change ports in `.env`, or restart the Host Network Service: `net stop winnat && net start winnat`. |
| Django auto-reload misses file changes | Inotify events across the Windows host → Docker Desktop Linux backend bind-mount can be lossy. | `docker compose restart app` to pick up the change. If it happens often, edit the same file once more to nudge the watcher, or keep a `docker compose logs -f app` window open so you notice when the reload didn't fire. |
| `gpcrdb-db` won't start, log says `could not resize shared memory segment` | Default `shm_size` interaction with WSL2. | The compose file already sets `shm_size: 2g`; if this still happens, increase Docker Desktop's resource allocation in Settings → Resources. |
| Docker Desktop WSL2 VHD grows huge after a `docker compose down -v` cycle | The VHD doesn't auto-shrink. | Quit Docker Desktop, run `wsl --shutdown`, then optimise: `Optimize-VHD -Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx" -Mode Full` (requires elevated PowerShell + Hyper-V module). |

## 11. When in doubt, drop into Git Bash

If a step in `onboarding.md` looks like it should "just work" but doesn't in PowerShell, opening Git Bash and running the literal upstream command is almost always faster than translating. Both shells share the same Docker engine and the same `.env`, so you can flip between them mid-session without restarting anything.
