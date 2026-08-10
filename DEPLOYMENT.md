# Deployment guide: build, push, auto-update

Packages the backend (multi-arch, with Hailo NPU support baked in only for arm64) and
frontend into Docker images, pushes them to GHCR from GitHub Actions on every push, and
runs Watchtower on the deployment machine so it picks up new images on its own.

Everything file-level (Dockerfile, workflows, compose files) is already written,
staged, and verified. The steps below are the parts that need your GitHub account,
credentials, and the actual remote machine - things this environment doesn't have
access to.

## 0. What's already done

- `build-docker/beaver-iot-api-npu.dockerfile` - multi-arch backend build, three Maven
  stages in the order that avoids Maven silently substituting published upstream
  artifacts for your local changes (see the comment block at the top of the file for
  why that order matters). Hailo binaries are baked in only for arm64 - verified with a
  real `docker buildx build` for both `linux/arm64` (native) and `linux/amd64` (QEMU):
  the former installs them, the latter skips them cleanly with no error.
- `.github/workflows/build-and-push.yml` - builds and pushes both images to GHCR,
  multi-arch, on `repository_dispatch` (fired by the other three repos on push) or
  manual `workflow_dispatch`.
- `beaver-iot/`, `beaver-iot-integrations/`, `beaver-iot-web/.github/workflows/notify-docker-build.yml`
  - fires that dispatch. Without this, pushing to those repos would do nothing, since
  the actual build lives in `beaver-iot-docker`.
- `deploy/docker-compose.yml` + `deploy/docker-compose.hailo.yml` - the deployment
  stack, validated with `docker compose config` (not just YAML syntax). Watchtower is
  scoped to just this stack via container labels, not every container on the host.
- All four repos: staged (`git add -A`), scanned for large/junk files first. Excluded:
  a 418MB build jar (already covered by the repo's own `*.jar` gitignore rule), a 1.2GB
  pnpm cache directory (added to `.gitignore` - it wasn't there before), and a stray
  scratch directory.

## 1. Commit (needs your git identity)

Not done - git isn't configured with an identity in this environment, and I don't set
`git config` myself. Run once:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

Then commit each repo (already staged, nothing further to add):

```bash
cd /home/pi/cytron-dashboard/beaver-iot-docker
git commit -m "Add multi-arch NPU backend build and Watchtower deploy pipeline"

cd /home/pi/cytron-dashboard/beaver-iot
git commit -m "Sync local changes: device template inline codec support, plus prior local work"

cd /home/pi/cytron-dashboard/beaver-iot-integrations
git commit -m "Sync local changes: custom device models for milesight-gateway, offline timeout sync, location bridge"

cd /home/pi/cytron-dashboard/beaver-iot-web
git commit -m "Sync local changes: map widget (base layer, trail, pulse), custom device model UI, offline timeout sync"
```

## 2. Create your own repos on GitHub

Done. Forked as:

| Local checkout | Fork |
|---|---|
| `beaver-iot` | `github.com/ZGMFX20AR/cytron-beaver-iot` (renamed on fork - not `beaver-iot`) |
| `beaver-iot-integrations` | `github.com/ZGMFX20AR/beaver-iot-integrations` |
| `beaver-iot-web` | `github.com/ZGMFX20AR/beaver-iot-web` |
| `beaver-iot-docker` | `github.com/ZGMFX20AR/beaver-iot-docker` |

`origin` on `upstream` (`Milesight-IoT/*`) remains as `upstream` on each, for pulling
future updates from there if wanted. `build-and-push.yml`'s `API_GIT_REPO_URL` is
updated to point at `cytron-beaver-iot` accordingly - if you ever rename it again,
that env var needs to change too, since GitHub doesn't redirect a git-clone-over-HTTPS
the way it redirects browser URLs on a rename.

(`beaver-iot-docker` has no upstream fork to speak of since it's small, but the same
pattern works - fork it too, for consistency and so `notify-docker-build.yml`'s
`repository_dispatch` target resolves correctly.)

You'll need push credentials configured - either an SSH key added to your GitHub
account, or a PAT used over HTTPS. Neither exists on this Pi yet.

## 3. Add the cross-repo dispatch token

`notify-docker-build.yml` in the three source repos needs to trigger a workflow in a
*different* repo (`beaver-iot-docker`) - the default `GITHUB_TOKEN` can't do that.

1. Create a **classic** PAT at github.com/settings/tokens with `repo` and `workflow`
   scopes.
2. Add it as a secret named `DISPATCH_TOKEN` in each of `beaver-iot`,
   `beaver-iot-integrations`, and `beaver-iot-web` (Settings → Secrets and variables →
   Actions → New repository secret). **Not** needed in `beaver-iot-docker` itself -
   that's the receiver, not the sender.

## 4. First build (manual, to confirm the pipeline works end to end)

Before relying on the automatic push-triggered path, run it once by hand:

`beaver-iot-docker` repo → Actions tab → "Build and Push (auto-deploy pipeline)" → **Run
workflow** → branch `main` for both inputs.

Expect this to take a while - the arm64 leg builds natively fast on GitHub's runners,
but the amd64 leg cross-compiles Java via QEMU emulation, which is slow for a Maven
build. Twenty-plus minutes for that leg alone would not be surprising. This is a
background CI job, so slowness itself isn't a problem - just don't expect it back in
five minutes.

Once it succeeds, two packages will appear under
`github.com/<your-username>?tab=packages`: `beaver-iot-api` and `beaver-iot-web`.

**Set their visibility.** New GHCR packages are private by default. Either:
- Make them public (Package settings → Change visibility) - simplest, no further auth
  needed anywhere, or
- Keep them private and authenticate on the deployment machine in step 5 - the compose
  file already mounts `~/.docker/config.json` into Watchtower for this case.

## 5. Deploy to the remote machine

On the remote machine:

```bash
# Install Docker + the Compose plugin if not already present
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in after this

# Only if the images are private (step 4):
docker login ghcr.io -u zgmfx20ar   # password = a PAT with read:packages
```

Copy `deploy/docker-compose.yml` (and `deploy/docker-compose.hailo.yml` if this machine
has the Hailo-10H) to the remote machine, then:

```bash
# Standard machine (amd64, or arm64 without the NPU):
IMAGE_OWNER=zgmfx20ar docker compose -f docker-compose.yml up -d

# Hailo-equipped arm64 machine - confirm the device node name first:
ls /dev/h1x-* /dev/hailo* 2>/dev/null
IMAGE_OWNER=zgmfx20ar \
  docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d
```

`IMAGE_OWNER` must be **lowercase** - Docker image references reject the account's
actual casing (`ZGMFX20AR`) outright, which is exactly what broke the first build
attempt (see the workflow's `IMAGE_OWNER` comment). GitHub's own URLs and `git clone`
are case-insensitive, so this only bites at the Docker layer, easy to miss.

Verify:
```bash
docker compose ps
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9200/   # expect 401 (reachable, needs auth)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # expect 200 (frontend)
```

## 6. Verify the auto-update loop, end to end

1. Make a trivial change in one of the three source repos, commit, push to `main`.
2. Watch that repo's Actions tab - `notify-docker-build.yml` should run and succeed
   within seconds.
3. Watch `beaver-iot-docker`'s Actions tab - "Build and Push" should start automatically,
   triggered by the dispatch. Wait for it to finish (see the timing note in step 4).
4. On the remote machine, `docker logs -f watchtower` - within `WATCHTOWER_POLL_INTERVAL`
   (300s / 5 min in the compose file), it should log finding and pulling the new image,
   then recreating the container.
5. Confirm the running container reflects the change (however you can observe it -
   version string, new feature behaviour, etc.).

If Watchtower's log shows it checked but found nothing new well past the poll interval,
the most common cause is the image tag mismatch - the compose file pins `:latest`, so
confirm the workflow actually pushed to `:latest` (it does, alongside the run-number
tag) and that the package visibility/auth from step 4 is actually working from this
machine (`docker pull ghcr.io/<you>/beaver-iot-api:latest` manually to isolate it from
Watchtower).

## 7. Rollback

Watchtower always moves you to `:latest`. If a push turns out to be broken:

```bash
# Find the last known-good run number from the beaver-iot-docker Actions history,
# then pin to it explicitly - this bypasses Watchtower until you're ready to move on:
docker compose stop beaver-iot-api
docker run -d --name beaver-iot-api-rollback \
  --network deploy_default \
  -p 9200:9200 -p 9201:9201 -p 1883:1883 -p 8083:8083 -p 11434:11434 \
  ghcr.io/<you>/beaver-iot-api:<old-run-number>
```

Or, more durably: push a revert commit to the source repo so the pipeline rebuilds
`:latest` from the last-good state, and let Watchtower pick that up on its next poll.

## Known limitations worth knowing about

- **`API_GIT_BRANCH` and `INTEGRATIONS_GIT_BRANCH` are the same value** in the workflow
  (both come from whichever repo triggered the dispatch, or the single manual input).
  This assumes you keep `beaver-iot` and `beaver-iot-integrations` on matching branch
  names in lockstep, which is how this session's work was done throughout. If you ever
  diverge (e.g. a feature branch in only one repo), the workflow will pull `main` from
  the other one - not necessarily wrong, but worth knowing about.
- **amd64 builds are slow** (QEMU-emulated Maven compilation). If this becomes painful,
  the fix is a native arm64 *and* a native amd64 runner instead of emulating one from
  the other - either GitHub's hosted arm64 runners (where available on your plan) or a
  self-hosted runner. Not set up here - it's a real decision (registering a runner has
  its own security surface) that deserves its own conversation rather than a default.
- **Hailo NPU features need the actual hardware**, not just the arm64 image. The binary
  is present on any arm64 build; without `/dev/h1x-0` passed through (the
  `docker-compose.hailo.yml` override), `LocalOllamaProcessManager` already logs a
  warning and continues without it - the app works, that one feature doesn't.
