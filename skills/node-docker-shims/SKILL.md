---
name: node-docker-shims
description: How node, npm, npx, yarn, pnpm, corepack and wrangler work on this machine. Each call runs in a throwaway Docker container through the secure-node-macos shims, and there is no host Node. Load this before running, installing or debugging any JavaScript or TypeScript tooling, and whenever a Node command fails in a surprising way, such as file not found for a path that exists, a dev server that localhost cannot reach, missing env vars, native module or "installed for another platform" errors (esbuild, rollup, workerd), install scripts that did not run, or a wrangler credentials prompt.
---

# Node runs in Docker on this machine

`node`, `npm`, `npx`, `yarn`, `pnpm` and `corepack` on PATH are bash shims from the secure-node-macos repo (`command -v node` shows where). There is no Node install on the host, on purpose: it keeps malicious npm packages away from the machine. Every call runs `docker run --rm`, so each command gets a fresh container and nothing persists inside it between calls.

Full documentation: `README.md` in the repo root, next to the `bin/` directory that holds the shims.

## Rules

- Do not install Node on the host (Homebrew, nvm, volta, fnm, installers) and do not suggest it as a fix.
- Do not set any of these unless the user asked for it in this task. Each one weakens the isolation:
  - `NODE_SHIMS_MODE=local` or `NODE_SHIMS_LOCAL=1` (runs tools on the host)
  - `NODE_SHIMS_WRANGLER_YES=1` (mounts Cloudflare credentials without the confirmation prompt)
  - `NODE_SHIMS_WRANGLER_AUTH=1` (passes Cloudflare credentials to every call)
  - `NODE_SHIMS_DOCKER=1` (gives the container the host Docker socket)
  - removing `ignore-scripts=true` from `~/.npmrc`
- When a task needs one of those, stop and tell the user what is needed and why.

## What the container can see

- The project directory, mounted at its real host path, so absolute paths under it work. Inside a workspace package (a parent has `pnpm-workspace.yaml` or `"workspaces"`), the workspace root is mounted instead.
- Absolute paths passed as arguments that exist outside the project, mounted one by one.
- npm, pnpm and yarn caches, `~/.npmrc`, and `~/.gitconfig` (read-only).
- Nothing else from `$HOME`: no `~/.ssh`, `~/.aws`, other repos or dotfiles. A script that reads them fails inside the container. That is expected, not a bug to work around.

## Environment variables

- Host env vars are not passed into the container.
- `op run --env-file=.env -- <command>` forwards everything `op` resolved, because the shim detects `op run` as its parent. Prefer this for secrets.
- Tools that read a `.env` file from the project directory work normally, since the file is mounted.

## Dev servers and ports

- Ports 3000, 5173, 8080, 4200, 3001, 4000, 5000 and 8787 are published when the command looks like a dev server (`dev`, `start`, `serve`, `vite`, `next`, ...). `DOCKER_NODE_PORTS=3000,9000` changes the list.
- The server must listen on `0.0.0.0`. A server bound to `localhost` inside the container cannot be reached from the host. Examples: `vite --host 0.0.0.0`, `next dev -H 0.0.0.0`, `[dev] ip = "0.0.0.0"` in `wrangler.toml`.

## Node version and image

- Version comes from `.nvmrc`, `.node-version` or `engines.node`, else the newest LTS. The image is `node:<version>-alpine`.
- Wrangler projects use `node:<version>-bookworm`, because workerd needs glibc.
- `NODE_IMAGE=node:24-alpine` overrides the image for one command.

## node_modules and native packages

- `node_modules` is written by Linux containers, so native packages (esbuild, Rollup, SWC, workerd) contain Linux binaries.
- Install commands record the platform in `node_modules/.node-shims-platform`. The warning `node_modules was installed for X, but this run is Y` means Alpine (musl), Debian (glibc) or macOS installs got mixed. Fix: `rm -rf node_modules`, then install again through the shims.

## Install scripts

- The repo's `.npmrc` template sets `ignore-scripts=true`. When `~/.npmrc` has it, postinstall and prepare scripts do not run. Packages that need them fail later (native addons, `husky`, `prisma generate`, `sharp`).
- Run the needed step explicitly (for example `npx prisma generate` or `npm rebuild <pkg>`), or ask the user before changing the setting.

## yarn and pnpm

- Provided by corepack inside the container, honouring `packageManager` in `package.json`.
- `corepack` is a shim too, so `corepack use pnpm@9` or `corepack pnpm --version` run in the container (on Node 25+ images, with the pinned corepack the shims install into `~/.cache/node-shims/corepack`).
- Corepack setup is skipped for `node` / `npm` / `npx` unless `package.json` mentions a package manager. If a tool spawns yarn or pnpm with no hint in `package.json`, run it with `NODE_SHIMS_COREPACK=1`.

## Wrangler (Cloudflare)

- Works in the container. Only calls that run wrangler for something that needs the Cloudflare API get credentials. `npm install` and local `wrangler dev` get none.
- The shim mounts only the wrangler profile a call uses, and asks `mount wrangler profile "<name>" credentials into the container? [y/N]` first.
- An agent shell has no terminal, so that prompt refuses and the command exits 1. Do not set `NODE_SHIMS_WRANGLER_YES=1` yourself. Tell the user the exact command so they can run it in their own terminal, or ask whether to set it for that one command.
- Prefer a scoped API token through `op run --env-file=.env -- npx wrangler ...` over `wrangler login`.
- Never deploy to a production profile (`--profile <prod>`) unless the user asked for that deploy.

## Symptoms and causes

| Symptom | Likely cause | What to do |
|---|---|---|
| `ENOENT` / "Cannot find module" for a file that exists on the host | File is outside the project mount | Move it into the project, or pass its absolute path as an argument |
| Dev server runs but `curl localhost:<port>` fails | Server bound to `localhost`, or port not published | Bind to `0.0.0.0`; check `DOCKER_NODE_PORTS` |
| `process.env.X` undefined | Host env vars are not forwarded | Use `op run --env-file=...` or a project `.env` file |
| "installed for another platform", missing `@esbuild/...` / `@rollup/...` binary | node_modules from another platform | `rm -rf node_modules` and reinstall through the shims |
| `yarn: not found` / `pnpm: not found` inside a script | Corepack skipped | `NODE_SHIMS_COREPACK=1` |
| Package works only after its postinstall | `ignore-scripts=true` | Run the setup step explicitly, or ask the user |
| "refusing to mount ... without confirmation (no terminal)" | Wrangler credentials prompt in a non-interactive shell | Ask the user (see Wrangler) |
| `Cannot connect to the Docker daemon` | Docker Desktop not running | Ask the user to start Docker (`open -a Docker`) |

## Debugging

- `NODE_SHIMS_DEBUG=1 <command>` prints the shim's decisions: extra mounts, forwarded env vars, wrangler credentials and profile.
- `node-shell` opens an interactive shell in the same container setup, for poking around.
