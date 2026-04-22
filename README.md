# NS8 GitHub Actions

Reusable automation scripts for [NethServer 8](https://github.com/NethServer/ns8-core) CI/CD pipelines.

## Workflows

| Workflow | Description |
|---|---|
| `test-module.yml` | Main entry point for module testing. Orchestrates `check-ui-tests-needed` and then runs tests on pre-provisioned infrastructure. |
| `test-on-digitalocean-infra.yml` | Provisions one or more NS8 clusters on DigitalOcean, runs the test script, and tears everything down. |
| `check-ui-tests-needed.yml` | Decides whether UI tests should run based on a configurable strategy (`on_ui_change`, `on_renovate_ui_change`, `never`) and detected file changes. |
| `publish-branch.yml` | Builds and publishes module container images. |
| `module-info.yml` | Resolves and exposes module metadata (name, tag, full image name, image list) as workflow outputs. |
| `build-apidoc.yml` | Generates API JSON Schema documentation. |
| `clean-apidoc.yml` | Removes previously generated API JSON Schema documentation. |
| `scan-with-trivy.yml` | Scans module images with [Trivy](https://trivy.dev/) for vulnerabilities, optionally generating an SBOM and updating the GitHub Dependency Graph. |

## Running tests locally

The `run-ns8-tests` script runs the `tests/` directory of **ns8-core** or any **NS8 module** with Robot Framework inside a Podman container, directly from your workstation against a live NS8 cluster.
The venv is cached in a named volume so repeated runs are fast.

### Requirements

- [Podman](https://podman.io/) available in `PATH`
- An SSH private key with access to the target NS8 leader node

### Installation

Download the script, make it executable, and place it in your `PATH`:

```bash
curl -o /tmp/run-ns8-tests https://raw.githubusercontent.com/NethServer/ns8-github-actions/refs/heads/v1/scripts/test-module.sh
install -m 0755 -Z /tmp/run-ns8-tests ~/.local/bin
```

### Usage

**Testing ns8-core** — enter the `core/` subdirectory of the ns8-core repository:

```bash
cd /path/to/ns8-core/core
run-ns8-tests <LEADER_NODE> [robot options...]
```

**Testing a module** — enter the module's repository root:

```bash
cd /path/to/ns8-<module>
run-ns8-tests <LEADER_NODE> <IMAGE_URL> [robot options...]
```

| Argument | Description |
|---|---|
| `LEADER_NODE` | Hostname or IP of the NS8 leader node |
| `IMAGE_URL` | Container image URL for the module under test *(module only, not used for core)* |
| `[robot options...]` | Any extra arguments forwarded to the `robot` command |

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SSH_KEYFILE` | `~/.ssh/id_ecdsa` | Path to the SSH private key |
| `RUN_UI_TESTS` | _(unset)_ | Set to `true` to enable UI/browser tests |
| `COREMODULES` | _(unset)_ | Space- or comma-separated list of core module images to install during cluster setup *(core only)* |

### Examples

#### ns8-core

Basic run:

```bash
cd ~/git/ns8-core/core
run-ns8-tests rl1.leader.cluster0.test.org
```

Skip installation and uninstallation tests (useful when the cluster is already set up):

```bash
cd ~/git/ns8-core/core
run-ns8-tests rl1.leader.cluster0.test.org --exclude install --exclude uninstall
```

With specific core modules and a custom SSH key:

```bash
cd ~/git/ns8-core/core
SSH_KEYFILE=~/.ssh/id_ecdsa COREMODULES="ghcr.io/nethserver/traefik:feat-7544" run-ns8-tests rl1.leader.cluster0.test.org
```

#### NS8 modules

Basic run:

```bash
cd ~/git/ns8-mail
run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/mail:bug-6977
```

Using a custom SSH key:

```bash
cd ~/git/ns8-mail
SSH_KEYFILE=~/.ssh/id_ecdsa run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/mail:bug-6977
```

With UI tests enabled:

```bash
cd ~/git/ns8-nextcloud
RUN_UI_TESTS=true run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/nextcloud:latest
```

With UI tests and a custom SSH key:

```bash
cd ~/git/ns8-nextcloud
SSH_KEYFILE=~/.ssh/id_ecdsa RUN_UI_TESTS=true run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/nextcloud:latest
```

Passing extra Robot Framework options (e.g. run a single test suite):

```bash
cd ~/git/ns8-mail
run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/mail:latest --suite "Sending mail"
```

Run only tests with a specific tag:

```bash
cd ~/git/ns8-mail
run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/mail:latest --include smoke
```

Run a single test by name:

```bash
cd ~/git/ns8-mail
run-ns8-tests rl1.leader.cluster0.test.org ghcr.io/nethserver/mail:latest --test "Send an email"
```

### How it works

- When `RUN_UI_TESTS=true`, the script uses the [Microsoft Playwright](https://playwright.dev/) container image and the `robotframework-browser` library.
- Otherwise, a lightweight `docker.io/python:3.11-slim` image is used.
- The Python venv is stored in a named volume (`rftest-cache` or `rftest-cache-ui`). It is invalidated automatically when the requirements file checksum changes.
- Robot Framework variables passed to all tests:
  - `NODE_ADDR` — the leader node address
  - `IMAGE_URL` — the module image URL *(module tests only)*
  - `SSH_KEYFILE` — path to the SSH key inside the container (`/tmp/idssh`)
  - `RUN_UI_TESTS` — whether UI tests are active
  - `COREMODULES` — space- or comma-separated list of core module images to install during cluster setup *(core tests only)*
- Tests tagged `unstable` are skipped on failure (`--skiponfailure unstable`).
- UI tests must be tagged `ui`; they are excluded automatically when `RUN_UI_TESTS` is not `true`.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) is configured via `renovate.json` using the shared `NethServer/.github:ns8` preset.

## See also

- [ns8-kickstart](https://github.com/NethServer/ns8-kickstart) — template repository for NS8 modules
