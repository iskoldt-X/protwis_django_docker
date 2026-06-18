# GPCRdb Docker Onboarding Tutorial

Welcome to the GPCRdb development environment! This tutorial is written for a new team member. It will walk you through setting up the local Docker stack, loading the database, and mastering the daily workflows required to contribute to the `protwis` Django application.

---

## 1. What this stack is

To run GPCRdb locally, you need a web server, a database, and a lot of data. In the past, this meant configuring Conda environments, installing complex system libraries, and managing a local PostgreSQL installation.

This Docker stack eliminates all of that. It provides three isolated containers:
1. **`gpcrdb-app`**: The Django web application running Python 3.8.
2. **`gpcrdb-db`**: PostgreSQL 16 equipped with the RDKit chemistry cartridge.
3. **`gpcrdb-adminer`**: A lightweight, web-based database management tool.

These containers communicate with your host machine through three directories:
- **`protwis`**: The GPCRdb source code. This is bind-mounted into the app container. Editing files here instantly updates the running application.
- **`gpcrdb_data`**: The massive data tree containing proteins, structures, etc.
- **`protwis_django_docker`**: This repository, which houses the Docker configuration.

## 2. Prerequisites

Before you start, ensure your host machine has:
- **Docker Desktop** installed and running.
- **~30 GB of free disk space** (the uncompressed PostgreSQL database takes up ~26 GB).
- **Git** and **cURL** available in your terminal.

*Note for Windows users:* We highly recommend using WSL2 (Windows Subsystem for Linux) and running all commands inside an Ubuntu WSL terminal rather than PowerShell.

## 3. First-time setup

### Step 3.1: Clone the repositories side-by-side
Open a terminal and create a workspace directory (e.g., `~/GitHub`), then clone the three necessary repositories so they sit next to each other.

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone -b dev_build https://github.com/protwis/protwis
git clone https://github.com/protwis/gpcrdb_data
git clone https://github.com/protwis/protwis_django_docker
```

> **Why the `dev_build` branch?** It carries the additive `settings_local_docker.py` / `settings_production_docker.py` files. The app container runs with `DJANGO_SETTINGS_MODULE=protwis.settings_local_docker`; clone the default branch instead and it crashes at startup with `ModuleNotFoundError`.

### Step 3.2: Configure the environment
Navigate into the docker repository and copy the environment template. For the default path, no manual edits are needed.

```bash
cd protwis_django_docker
cp .env.example .env
```

### Step 3.3: Bring up the stack
Ask Docker to download the images and start the containers in the background (`-d`).

```bash
docker compose up -d
```

Docker will pull the images and create the containers. You can verify they are running:
```bash
docker compose ps
```
Wait until the `gpcrdb-db` container shows as `(healthy)`. The Django `app` container waits for the database to be healthy before it fully starts.

## 4. Loading the GPCRdb dump

The GPCRdb database contains hundreds of thousands of entries. We distribute it as a massive compressed SQL dump (`~4.3 GB` compressed, `~26 GB` uncompressed).

### Step 4.1: Download the dump
Download the latest dump from the GPCRdb servers (this may take a few minutes depending on your connection):
```bash
curl -L https://files.gpcrdb.org/protwis_sp.sql.gz -o ~/protwis.sql.gz
```

### Step 4.2: Load into Postgres
We pipe the uncompressed data directly into the database container. We use the `-q` (quiet) and `-1` (single transaction) flags to make the import as fast and safe as possible.

```bash
gunzip -c ~/protwis.sql.gz | docker exec -i gpcrdb-db psql -U protwis -d protwis -q -1
```

**Wait patiently.** This process will take **10 to 20 minutes**, depending on your CPU and disk speed. Because we use a single transaction (`-1`), the database will appear empty to outside observers until the very last second when the transaction commits.

## 5. Applying Django migrations

The SQL dump you just downloaded represents a snapshot of the database at a specific point in time. However, the `protwis` Django source code is constantly evolving.

Because of this **dump-vs-code drift**, the code may expect database columns that don't exist in the older dump.

To bring your database schema up to date with the code, run:
```bash
docker compose exec app python manage.py migrate
```

You should see Django successfully applying a few remaining migrations. You can now visit http://localhost:8000!

## 6. Daily-use commands

Here are the commands you will use every day. All commands should be run from inside the `protwis_django_docker` directory.

- `docker compose up -d` : Start the stack in the background.
- `docker compose down` : Stop the stack safely (preserves your database volume).
- `docker compose logs -f app` : Follow the live logs of the Django app (press Ctrl+C to exit).
- `docker compose exec app bash` : Open an interactive bash shell *inside* the Django container.
- `docker compose exec app python manage.py <cmd>` : Run a specific Django command inside the container.

## 7. Editing protwis source

The `protwis` source code on your host machine (e.g., in `~/GitHub/protwis`) is bind-mounted into the `gpcrdb-app` container at `/app/src`. 

This means **you do not need to rebuild the Docker image to see code changes**.
1. Open the `protwis` folder in VSCode or your favorite IDE on your host machine.
2. Edit a Python file (e.g., a view or a model).
3. The Django `runserver` process inside the container automatically detects the change and reloads itself.

*Troubleshooting Auto-reload:* Sometimes, structural changes (like adding a completely new app) might confuse the auto-reloader. If the site feels "stuck" on old code, restart the app container cleanly:
```bash
docker compose restart app
```

## 8. Running Django management commands

GPCRdb relies heavily on custom `manage.py` commands to build data. 

### The Pattern
You will **always** run commands like this:
```bash
docker compose exec app python manage.py <command_name>
```

For commands that take a long time (minutes to hours), you should detach (`-d`) and disable TTY allocation (`-T`), then watch the logs separately so your terminal isn't held hostage:
```bash
docker compose exec -T -d app python manage.py build_protein_structures
docker compose logs -f app
```

### Self-Discovery
Do not rely on static cheat sheets; they get outdated quickly. To see every command available in the codebase, ask Django:
```bash
docker compose exec app python manage.py help
```

### The 5 Categories of Commands
When you run a command, it will fall into one of five categories. We have run a canonical example for each to show you what to expect:

1. **Built-in Django:** Commands shipped with the framework.
   - *Example:* `migrate` (Takes seconds, prints "Applying... OK")
2. **Read-only Diagnostic:** Quick, safe commands that illuminate the system state.
   - *Example:* `dbshell` or `shell`. Drops you into an interactive REPL.
3. **Small Data Update:** Quick builders that modify specific tables.
   - *Example:* `build_links`. We ran this and it updated `121,411` rows in **~53 seconds** silently and idempotently.
4. **Long Build Pipeline:** Heavy data processors that crunch PDB files or alignments.
   - *Example:* `build_homology_models`. Will run for hours. Always use the `-T -d` detached pattern!
5. **Modeller-Requiring:** Some commands require the proprietary `modeller` package.
   - *Example:* `build_complex_models` or `check_knots`.
   - *What happens:* If you run these, they will crash instantly with `ModuleNotFoundError: No module named 'modeller'`. This is **expected** because `modeller` requires a paid license and cannot be shipped in our public Docker image. Do not run these commands locally unless you manually install Modeller into your container.

## 9. Resetting the database

If your database gets corrupted or you just want to start completely fresh, you must perform a destructive reset. **This will delete your 26 GB data volume.**

```bash
docker compose down -v
# The -v flag tells Docker to destroy named volumes!
```
Once destroyed, simply run `docker compose up -d` to create a fresh, empty database, and repeat Step 4 to load the dump again.

## 10. Running a second stack for comparison

Often, you want to test a massive code refactor by comparing it side-by-side with the `master` branch. Docker allows you to run two completely isolated GPCRdb stacks on the same machine simultaneously.

### The Setup
1. Clone a second copy of protwis: `git clone -b dev_build https://github.com/protwis/protwis ../protwis-alt`
2. Create an alternate environment file in your docker repo: `cp .env.example .env.alt`
3. Edit `.env.alt` to change the project name and the host ports:
```bash
COMPOSE_PROJECT_NAME=gpcrdb-alt
APP_PORT=8001
DB_PORT=5433
ADMINER_PORT=8889
PROTWIS_SRC=../protwis-alt
```
4. Start the alternate stack: `docker compose --env-file .env.alt up -d`

### Scenarios
- **Code diff (Most Common):** Two checkouts, two isolated databases, sharing the same `gpcrdb_data` tree. (Setup shown above).
- **Dump diff:** One checkout, two isolated databases loaded with different SQL dumps. 
- **Fully isolated:** Two of everything. 

### ⚠️ Crucial Concept: Host vs. Container Ports
In the `.env.alt` file, we changed the `DB_PORT` to `5433`. **This only changes the port exposed to your host machine.** If you want to connect using a GUI like DBeaver from your Mac/Windows, you connect to `localhost:5433`.

However, **inside the Docker network**, the `gpcrdb-alt-app` container still connects to its database at `db:5432`. The Django application is entirely unaware of the host mapping. 

### Hot-Reload Isolation
When running dual stacks, editing a Python file in `../protwis` will trigger a Django reload *only* in the main `gpcrdb-app`. Editing `../protwis-alt` triggers a reload *only* in `gpcrdb-alt-app`. The bind mounts are truly isolated.

## 11. Troubleshooting

| Symptom | Diagnosis / Cause | Fix |
|---|---|---|
| `column foo.bar does not exist` | Dump-vs-code schema drift. Your code expects a table column the dump didn't have. | Run `docker compose exec app python manage.py migrate` |
| `ModuleNotFoundError: No module named 'modeller'` | Command requires the proprietary modeller package. | Do not run this command locally without a manual Modeller license install. |
| Command appears to hang forever | Build commands can take hours and provide no console output. | Check if it's running via `docker compose exec app top`. Next time, run detached. |
| `psql: error: connection to server at "localhost"... failed: FATAL: role "your_mac_username" does not exist` | You forgot the `-U protwis -d protwis` flags when running the host `psql` command. | Add the correct user and database flags. |
| `port is already allocated` on `docker compose up` | You have a ghost Django process running natively on your Mac, or another Docker stack is using port 8000/5432. | Find the process using the port (`lsof -i :8000`) and kill it, or use `.env.alt` to shift ports. |

## 12. Updating the image

When upstream developers change system dependencies (like adding a new Ubuntu package) or update Python requirements in `pyproject.toml`, you need to update your image.

- **If the changes were pushed to GitHub:** Simply run `docker compose pull app` to fetch the pre-built image, then `docker compose up -d` to restart.
- **If you are testing changes to `Dockerfile` or `pyproject.toml` locally:** Run `docker compose build app` to force Docker to build a new image from your local files.

### Trying a different (Python, Django, RDKit) combination

The repo also publishes one image tag per combination of major versions, produced by a manually-triggered compatibility-matrix workflow. See [`docs/compatibility-matrix.md`](compatibility-matrix.md) for the live list — every green cell links to a pullable tag like `ghcr.io/protwis/protwis_django_docker:matrix-py311-dj42-rdk202409`. To try one, set `app.image` to that tag in `docker-compose.yml` and `docker compose up -d --force-recreate app`. These are *probe* images: the docker env is known to build, but upstream protwis code may or may not run on a non-baseline combination.

### Adding a new version to the matrix

The matrix is intentionally easy to extend years from now. The single source of truth is [`scripts/matrix_versions.py`](../scripts/matrix_versions.py) — three Python lists, one per axis. Append a `(pin, upper-bound-exclusive)` tuple to add a row:

```python
PYTHON.append(("3.13", "3.14"))     # Python 3.13
DJANGO.append(("6.2", "7.0"))       # Django 6.2 LTS
RDKIT.append(("2027.03", "2027.04")) # RDKit 2027.03 stable
```

Commit, dispatch the **Compatibility Matrix** workflow from the GitHub Actions UI, and the new cells appear in `docs/compatibility-matrix.md` after the run finishes. The workflow, the cell driver, and the template are version-agnostic; you never need to touch them.

## 13. Where to look next

- Check out the upstream [protwis repository](https://github.com/protwis/protwis) for the application code.
