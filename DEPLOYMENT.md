# Deployment guide: build, push, deploy, update

Packages the backend (multi-arch, with Hailo NPU support baked in only for arm64) and
frontend into Docker images and pushes them to GHCR from GitHub Actions on every push.
Two ways to actually run it on a machine:

- **Monolith** (`ghcr.io/zgmfx20ar/beaver-iot`) - one container, one `docker run`,
  matches Milesight's own official image UX exactly. Updates are manual (`docker pull` +
  restart), same as Milesight's own documented upgrade process.
- **Split stack** (`beaver-iot-api` + `beaver-iot-web` + Watchtower, via docker-compose)
  - two containers instead of one, but Watchtower polls GHCR and updates itself
  automatically, no manual pull needed.

Status: **the full pipeline is built, fixed, and verified end to end**, both paths -
source push → CI build → GHCR → running container, confirmed on a real remote arm64
machine (no Hailo). Sections 1-5 below are done and kept for reference / reproducing on
a fresh fork. Section 6 is what you'll actually re-run for each new machine.

## 0. What's already done

- `build-docker/beaver-iot-api-npu.dockerfile` - multi-arch backend build, three Maven
  stages in the order that avoids Maven silently substituting published upstream
  artifacts for your local changes (see the comment block at the top of the file for
  why that order matters). Hailo binaries are baked in only for arm64. Also carries
  `JAVA_OPTS`/`SPRING_OPTS` env vars and `-Dloader.path=${HOME}/beaver-iot/integrations`,
  matching upstream's own API image - a mount point for user-provided extra integration
  jars at runtime, on top of (not instead of) the milesight-gateway integration already
  compiled into the jar at build time.
- `build-docker/beaver-iot-monolith.dockerfile` - combines the api and web images into
  one container (nginx + java, single process tree) for `docker run` parity with
  Milesight's own image. Ported from Milesight's own `beaver-iot.dockerfile`, which
  assumes an Alpine base - ours is Debian (`debian:trixie-slim`, for the Hailo deps), so
  the nginx + headers-more-filter module install goes through `apt` instead of `apk`.
- `.github/workflows/build-and-push.yml` - builds and pushes all three images to GHCR on
  `repository_dispatch` (fired by the other three repos on push) or manual
  `workflow_dispatch`. The backend build is split into `build-backend-amd64` (native,
  `ubuntu-latest`) and `build-backend-arm64` (native, `ubuntu-24.04-arm`), combined into
  one multi-arch manifest by `build-backend-manifest` - see "Why the backend build is
  split into three jobs" below. `build-monolith` runs last, depending on both
  `build-backend-manifest` and `build-frontend` finishing, since it builds from their
  `:latest` output rather than compiling anything itself.
- `beaver-iot/`, `beaver-iot-integrations/`, `beaver-iot-web/.github/workflows/notify-docker-build.yml`
  - fires that dispatch on push to `main`. Without this, pushing to those repos would do
  nothing, since the actual build lives in `beaver-iot-docker`.
- `deploy/docker-compose.yml` + `deploy/docker-compose.hailo.yml` - the split-stack
  deployment, for the auto-updating path. Watchtower is scoped to just this stack via
  container labels, not every container on the host.
- All four repos: committed and pushed to your forks.

## 1. Fork map

| Local checkout | Fork | What lives here |
|---|---|---|
| `beaver-iot` | `github.com/ZGMFX20AR/cytron-beaver-iot` (renamed on fork) | Backend core - API, database, business logic |
| `beaver-iot-integrations` | `github.com/ZGMFX20AR/beaver-iot-integrations` | Backend integrations - e.g. Milesight Gateway / LoRaWAN device handling |
| `beaver-iot-web` | `github.com/ZGMFX20AR/beaver-iot-web` | Frontend - dashboard, widgets, everything in the browser |
| `beaver-iot-docker` | `github.com/ZGMFX20AR/beaver-iot-docker` | Not app features - Dockerfiles, the CI workflow, and the compose files |

`upstream` remains configured as a remote (`Milesight-IoT/*`) on each, for pulling
future updates from there if wanted. `build-and-push.yml`'s `API_GIT_REPO_URL` points at
`cytron-beaver-iot` accordingly - if you ever rename that fork again, that env var needs
to change too, since GitHub doesn't redirect a git-clone-over-HTTPS the way it redirects
browser URLs on a rename.

## 2. Making a change and shipping it

1. Edit code in whichever repo matches the table above (frontend widget → `beaver-iot-web`,
   API logic → `beaver-iot`, integration behavior → `beaver-iot-integrations`).
2. Commit and push to `main`:
   ```bash
   git add <files>
   git commit -m "describe the change"
   git push origin main
   ```
3. That push alone does the rest automatically: `notify-docker-build.yml` in that repo
   fires a `repository_dispatch` to `beaver-iot-docker`, which rebuilds **all three**
   images (`beaver-iot-api`, `beaver-iot-web`, and the `beaver-iot` monolith) and pushes
   them fresh to GHCR - usually done in 15-20 minutes. It always rebuilds everything on
   any dispatch, not just the piece that changed, so the monolith and split-stack images
   never drift out of sync with each other.
4. Getting the new image onto a deployment machine depends on which path that machine
   uses - see section 6 for each.

`beaver-iot-docker` itself is the exception - editing a Dockerfile, the workflow, or the
compose files doesn't need a source-repo push to take effect; just commit and push
`beaver-iot-docker` directly, then trigger a build manually (Actions tab → "Build and
Push (auto-deploy pipeline)" → **Run workflow**), since that repo has no `push` trigger
of its own - only `repository_dispatch` and `workflow_dispatch`.

## 3. Cross-repo dispatch token (already configured)

`notify-docker-build.yml` in the three source repos needs to trigger a workflow in a
*different* repo (`beaver-iot-docker`) - the default `GITHUB_TOKEN` can't do that, so a
classic PAT (`repo` + `workflow` scopes) is stored as the `DISPATCH_TOKEN` secret in
`beaver-iot`, `beaver-iot-integrations`, and `beaver-iot-web` (not needed in
`beaver-iot-docker` itself - that's the receiver, not the sender). If you ever rotate or
recreate that PAT, it needs a fine-grained token with **Contents: Read and write** and
`beaver-iot-docker` explicitly in its repository access list, or you'll hit
`403 Resource not accessible by personal access token` on the dispatch step. The repo's
own Settings → Actions → General → "Workflow permissions" also needs to be **read and
write**, not the read-only default - that's a separate ceiling on top of the token scope
and caps `packages: write` in the workflow even with a correctly-scoped token.

## 4. Why the backend build is split into three jobs

The first version combined `linux/amd64,linux/arm64` into one `docker buildx build` on
`ubuntu-latest` (amd64). That meant the arm64 leg had to be QEMU-emulated, and running a
3-stage Maven Reactor clone-and-build under QEMU regularly took 90+ minutes with no
guarantee of finishing - Java/Maven compilation is exactly the kind of CPU-heavy
workload QEMU user-mode emulation handles worst.

Since this is a public repo, GitHub provides free hosted native arm64 runners
(`ubuntu-24.04-arm`). The backend build is now:
- `build-backend-amd64` - native, `ubuntu-latest`, pushes to an intermediate `:<run>-amd64` tag
- `build-backend-arm64` - native, `ubuntu-24.04-arm`, pushes to `:<run>-arm64`
- `build-backend-manifest` - combines both into the real `:latest` / `:<run>` tags via
  `docker buildx imagetools create`, once both finish

Both per-arch legs typically finish in **10-15 minutes each, in parallel** - a ~6-9x
improvement over the QEMU path, and this time it actually finishes. `build-frontend`
wasn't restructured this way (it's a much lighter build); it still QEMU-emulates its
arm64 leg and takes roughly 20 minutes cold, well under a minute on a cache hit.
`build-monolith` doesn't need this treatment either - it doesn't compile anything, just
layers nginx onto the already-built api image, so QEMU on its emulated leg is cheap
regardless (under 2 minutes in practice).

All three images are **private** (GHCR's default for a new package - nothing to
configure). Every machine that pulls them needs to authenticate first, covered in
section 6.

## 5. Line-ending fix (already applied, just context)

Every file in this fork that was copied from Milesight's upstream repo had CRLF line
endings baked into its committed blob - confirmed by diffing against `upstream/main`
byte-for-byte after stripping `\r`, which showed zero actual content differences on any
of the 16 affected files. This broke two shell scripts' shebangs specifically
(`build-docker/docker-entrypoint.sh` and `build-docker/nginx/envsubst-on-templates.sh`),
which is what crash-looped the `beaver-iot-web` container on first deployment ("exec
/docker-entrypoint.sh: no such file or directory", then "/envsubst-on-templates.sh: not
found" after only the first script was initially fixed). All 16 files are now normalized
to upstream's clean LF endings. If you ever edit any file in this repo from a
Windows-line-ending-producing tool, watch for this class of bug recurring.

## 6. Deploy to a remote machine

Both paths start the same way:

```bash
# Install Docker + the Compose plugin if not already present
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in after this for the group change to apply

# Images are private - authenticate first
docker login ghcr.io -u zgmfx20ar   # password = a PAT with read:packages
```

### 6a. Monolith - one container, manual updates

Verified against a real arm64 machine (no Hailo). `-v $(pwd)/beaver-iot:/root` gives the
container a dedicated data folder on the host, separate from anything else in your
working directory (don't mount your whole working directory to `/root` if it has other
files in it, like a compose file from the split-stack path - the container will write
its own internal state directly into it, mixed in with your own files):

```bash
mkdir -p beaver-iot
docker run -d --name beaver-iot \
  -v $(pwd)/beaver-iot:/root \
  -p 5100:80 -p 1883:1883 \
  --hostname beaver-iot \
  -e BEAVER_IOT_API_HOST=localhost \
  ghcr.io/zgmfx20ar/beaver-iot:latest
```

`--hostname beaver-iot` matters, not just cosmetic - see the `UnknownHostException`
entry in Troubleshooting. `-e BEAVER_IOT_API_HOST=localhost` tells nginx to reach the
API on the same container rather than a separate one, since with the monolith there's
only one.

Verify:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5100/   # expect 200
```

**Upgrade** (matches Milesight's own documented pattern exactly - manual, not automatic):
```bash
docker stop beaver-iot
docker rm beaver-iot
docker pull ghcr.io/zgmfx20ar/beaver-iot:latest

docker run -d --name beaver-iot \
  -v $(pwd)/beaver-iot:/root \
  -p 5100:80 -p 1883:1883 \
  --hostname beaver-iot \
  -e BEAVER_IOT_API_HOST=localhost \
  ghcr.io/zgmfx20ar/beaver-iot:latest
```
The bind-mounted `beaver-iot/` folder persists your data across this cycle.

### 6b. Split stack - two containers, auto-updates via Watchtower

Pull just the compose file - no need to clone the whole repo:

```bash
curl -o docker-compose.yml https://raw.githubusercontent.com/ZGMFX20AR/beaver-iot-docker/main/deploy/docker-compose.yml
```

Set `IMAGE_OWNER` via a `.env` file next to the compose file, not an inline shell
variable - `VAR=value some-command` only applies to that one invocation, so every
subsequent `docker compose` call (including Watchtower's own recreate cycles) would
otherwise fail to interpolate it:

```bash
echo "IMAGE_OWNER=zgmfx20ar" > .env
```

Bring the stack up:

```bash
# Standard machine (amd64, or arm64 without the NPU):
docker compose -f docker-compose.yml up -d

# Hailo-equipped arm64 machine only - confirm the device node name first:
ls /dev/h1x-* /dev/hailo* 2>/dev/null
curl -o docker-compose.hailo.yml https://raw.githubusercontent.com/ZGMFX20AR/beaver-iot-docker/main/deploy/docker-compose.hailo.yml
docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d
```

`IMAGE_OWNER` must be **lowercase** - Docker image references reject the account's
actual casing (`ZGMFX20AR`) outright. GitHub's own URLs and `git clone` are
case-insensitive, so this only bites at the Docker layer, easy to miss.

Verify:
```bash
docker compose -f docker-compose.yml ps
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9200/   # expect 401 (API reachable, needs auth)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # expect 200 (frontend)
```

All three containers (`beaver-iot-api`, `beaver-iot-web`, `watchtower`) should show `Up`
in `docker compose ps`. If any of them are `Restarting`, see Troubleshooting below.

**Don't run both paths on the same machine at the same host ports** - the split stack's
`beaver-iot-api` and the monolith both want port `1883` (MQTT) by default; starting the
second one while the first is still up will fail with `port is already allocated`. Stop
one first (`docker compose -f docker-compose.yml down` for the split stack), or use
different `-p` mappings if you genuinely want both running side by side for comparison.

## 7. Verify the split-stack auto-update loop, end to end

Only applies to the split-stack path (6b) - the monolith updates manually, by design,
matching Milesight's own image.

1. Make a trivial change in one of the three source repos, commit, push to `main`
   (section 2).
2. Watch that repo's Actions tab - `notify-docker-build.yml` should run and succeed
   within seconds.
3. Watch `beaver-iot-docker`'s Actions tab - "Build and Push" should start automatically,
   triggered by the dispatch. Backend legs typically finish in 10-15 minutes each
   (parallel); frontend in under a minute on a cache hit, ~20 minutes cold.
4. On the remote machine, `docker logs -f watchtower` - within `WATCHTOWER_POLL_INTERVAL`
   (300s / 5 min in the compose file), it should log finding and pulling the new image,
   then recreating the container.
5. Confirm the running container reflects the change.

If Watchtower's log shows `scanned=0` on every "Update session completed" line, it isn't
finding your containers at all - check the label typo in Troubleshooting below before
anything else. If it shows a nonzero `scanned` count but `updated=0` well past the poll
interval, the more likely cause is an image tag mismatch - the compose file pins
`:latest`, so confirm the workflow actually pushed to `:latest` (the manifest job does,
alongside the run-number tag) and that auth from section 6 is actually working from this
machine (`docker pull ghcr.io/zgmfx20ar/beaver-iot-api:latest` manually to isolate it
from Watchtower).

## 8. Troubleshooting

Real failures hit during the first deployments, in case they recur on a new machine or
after a manual edit to the compose file / Dockerfiles:

- **`beaver-iot-web` restarting, logs show `exec /docker-entrypoint.sh: no such file or
  directory`** (or, after only a partial fix, `/envsubst-on-templates.sh: not found`) -
  this was the CRLF line-ending bug described in section 5, already fixed in this repo.
  If it recurs, check `git show HEAD:<path> | cat -A` for `^M$` (literal `\r`) at line
  ends on any shell script that gets `COPY`'d into an image and run.
- **`watchtower` restarting, logs show `client version 1.25 is too old. Minimum
  supported API version is 1.40`** - the `containrrr/watchtower` project is archived
  (Feb 2024) and its `:latest` tag had gone stale on this architecture, resolving to an
  image with an ancient bundled Docker API client. Fixed by switching the compose file
  to `ghcr.io/nicholas-fedor/watchtower:latest`, the actively maintained continuation.
- **`beaver-iot-api` (or the monolith) crash-looping on startup with
  `UnknownHostException: <container-id>: Temporary failure in name resolution`** inside
  `SnowflakeUtil` - the app's ID generator calls `InetAddress.getLocalHost()` at boot,
  which failed to resolve Docker's auto-generated random container-ID hostname on this
  host's network setup. Fixed by adding an explicit `hostname:` (compose) or
  `--hostname` (`docker run`) - `container_name` alone does **not** set the container's
  actual OS-level hostname, which is easy to assume it does.
- **Watchtower runs fine, polls on schedule, but never updates anything - `docker logs
  watchtower` shows `scanned=0` on every single "Update session completed" line**, even
  though `beaver-iot-api` and `beaver-iot-web` are both clearly `Up` - the compose file
  had a typo in the label Watchtower filters on: `com.centurylabs.watchtower.enable`
  instead of the real, documented label,
  **`com.centurylinklabs.watchtower.enable`** (CenturyLink Labs - Watchtower's original
  creator; confirmed against containrrr.dev/watchtower/container-selection/). With
  `WATCHTOWER_LABEL_ENABLE=true` set, the typo meant Watchtower's label filter matched
  zero containers, silently, from the very first deployment - it looked completely
  healthy the whole time (`(healthy)` in `docker compose ps`, clean logs, no errors) with
  nothing actually in scope to update. Already fixed in the compose file; if you're
  running an older pull of it, re-fetch and `docker compose up -d` to apply the label
  fix (no image rebuild needed for this one).
- **`docker compose` commands fail with `required variable IMAGE_OWNER is missing a
  value`** after a working `IMAGE_OWNER=zgmfx20ar docker compose ... up -d` - the
  inline-variable form only applies to that one command. Use the `.env` file approach in
  section 6b instead.
- **`docker run` for the monolith fails with `Bind for :::1883 failed: port is already
  allocated`** - something else on the machine (usually the split stack's
  `beaver-iot-api`) already has that port. See the note at the end of section 6b.
- **Monolith's data files show up mixed in with unrelated files in your working
  directory** - you mounted the directory containing other stuff (like a leftover
  compose file) straight to `/root` via `-v $(pwd):/root`. The container writes its own
  internal state under `/root/...`, which lands directly in whatever host folder you
  pointed at. Use a dedicated subfolder instead, e.g. `-v $(pwd)/beaver-iot:/root`.

## 9. Rollback

**Monolith**: pin to an old run-number tag instead of `:latest`:
```bash
docker stop beaver-iot && docker rm beaver-iot
docker run -d --name beaver-iot \
  -v $(pwd)/beaver-iot:/root \
  -p 5100:80 -p 1883:1883 \
  --hostname beaver-iot \
  -e BEAVER_IOT_API_HOST=localhost \
  ghcr.io/zgmfx20ar/beaver-iot:<old-run-number>
```

**Split stack**: Watchtower always moves you to `:latest`. If a push turns out to be
broken:
```bash
# Find the last known-good run number from the beaver-iot-docker Actions history,
# then pin to it explicitly - this bypasses Watchtower until you're ready to move on:
docker compose -f docker-compose.yml stop beaver-iot-api
docker run -d --name beaver-iot-api-rollback \
  --network deploy_default \
  -p 9200:9200 -p 9201:9201 -p 1883:1883 -p 8083:8083 -p 11434:11434 \
  ghcr.io/zgmfx20ar/beaver-iot-api:<old-run-number>
```

Or, more durably (either path): push a revert commit to the source repo so the pipeline
rebuilds `:latest` from the last-good state.

## Known limitations worth knowing about

- **`API_GIT_BRANCH` and `INTEGRATIONS_GIT_BRANCH` are the same value** in the workflow
  (both come from whichever repo triggered the dispatch, or the single manual input).
  This assumes you keep `beaver-iot` and `beaver-iot-integrations` on matching branch
  names in lockstep. If you ever diverge (e.g. a feature branch in only one repo), the
  workflow will pull `main` from the other one - not necessarily wrong, but worth
  knowing about.
- **`build-frontend` still QEMU-emulates its arm64 leg** - only the backend build was
  split into native per-arch jobs, since that was the one regularly failing to finish.
  Frontend builds are light enough (~20 min cold, seconds on a cache hit) that this
  hasn't been worth restructuring the same way, but it's the same class of slowness if
  it ever becomes a problem.
- **Hailo NPU features need the actual hardware**, not just the arm64 image. The binary
  is present on any arm64 build; without `/dev/h1x-0` passed through (the
  `docker-compose.hailo.yml` override), `LocalOllamaProcessManager` already logs a
  warning and continues without it - the app works, that one feature doesn't.
- **The monolith doesn't auto-update.** That's intentional (matches Milesight's own
  image), not a gap to fix - if you want it to, the same Watchtower container from the
  split stack can be run alongside it with the same label, but that's a deliberate
  addition, not the default.
