# test-module-qemu.yml

What a module should call: it gathers the module information, decides whether
the UI tests are worth running, resolves the baseline for the update scenario,
and fans out over distributions and scenarios, calling
[`test-on-qemu.yml`](test-on-qemu.md) once per leg. Call that one directly only
when you need a single leg under your own conditions.

Drop-in replacement for
[`test-module.yml`](../.github/workflows/test-module.yml),
running on a throwaway QEMU node instead of a DigitalOcean droplet. The name
says QEMU rather than matching the file it replaces: both could end up in the
same repository one day, and two `.github/workflows/test-module.yml` cannot.

- [Moving a module off DigitalOcean](#moving-a-module-off-digitalocean)
- [Inputs](#inputs)
- [Scenarios](#scenarios)
- [The pull request status, comment and their token](#the-pull-request-status-comment-and-their-token)
- [What a suite may rely on](#what-a-suite-may-rely-on)

## Moving a module off DigitalOcean

Change the path in `uses:`, and drop the `secrets:` block. The secret is still
accepted, and ignored, so a caller that keeps it works unchanged.

```diff
 jobs:
   run:
     name: "Run tests"
+    permissions:
+      contents: read
+      pull-requests: write
+      statuses: write
-    uses: NethServer/ns8-github-actions/.github/workflows/test-module.yml@v1
+    uses: NethServer/ns8-github-actions/.github/workflows/test-module-qemu.yml@v1
     with:
       ui_tests_strategy: on_renovate_ui_change
       debug_shell: ${{ github.event.inputs.debug_shell == 'true' }}
-    secrets:
-      do_token: ${{ secrets.do_token }}
```

The `permissions` block is the one addition. It lets the wrapper report each
leg on the pull request and post the screenshots as a comment. See
[below](#the-pull-request-status-comment-and-their-token).

Also worth adding at the top of the caller file, next to `name:`:

```yaml
run-name: "Test ${{ github.event.workflow_run.head_branch || github.ref_name }} on QEMU"
```

Under `workflow_run` every run belongs to the default branch, so the Actions
list shows them all as the workflow name, with nothing saying what was tested.
A called workflow cannot set its caller's `run-name`, so this line lives in the
module.

## Inputs

Identical to the Nethesis wrapper:

| Input | Default | Description |
|---|---|---|
| `ui_tests_strategy` | `on_renovate_ui_change` | `always`, `on_ui_change`, `on_renovate_ui_change` or `never`. Evaluated by `check-ui-tests-needed.yml` of `ns8-github-actions`, so the vocabulary is the same on both CI |
| `debug_shell` | `false` | Open a tmate shell when the suite fails |

What the module under test is:

| Input | Default | Description |
|---|---|---|
| `image_name` | _(derived)_ | Only when `reponame` in `build-images.sh` differs from the repository name minus its `ns8-` prefix. Empty derives it, which is right for most modules |
| `path` | `""` | Subdirectory holding the module |
| `script` | `""` | Empty runs the shared `scripts/test-module.sh`, which is what a module should want. A named script never receives `-v SCENARIO:`, since it was not written to expect it |
| `ci_actions_ref` | `v1` | Ref this repository is read at for that shared runner. Pass the same ref as `uses:` when testing a branch of `ns8-github-actions` |

What to cover:

| Input | Default | Description |
|---|---|---|
| `distros` | `["rocky9","debian13"]` | JSON array of guest distributions. `debian12` is also supported |
| `scenarios` | `["install"]` | JSON array. See [Scenarios](#scenarios) |
| `update_from` | _(resolved)_ | Tag the update scenario starts from. Empty takes the newest non-prerelease release, then falls back to `latest` |
| `ui_test_distro` | `rocky9` | Publish screenshots from this leg only |
| `ui_test_scenario` | `install` | Publish screenshots from this scenario only |

Guest and runner sizing, all forwarded to `test-on-qemu.yml` unchanged:
`corebranch`, `install_args`, `cloud_image_url`, `runs_on`, `vm_mem`,
`vm_cpus`, `disk_size`, `timeout_minutes`. See
[its own documentation](test-on-qemu.md#inputs) for what each one does.

`distros` and `scenarios` multiply, so pass `scenarios: '["install","update"]'`
only once the suite is ready for it: see [Scenarios](#scenarios) for why.

## Scenarios

`install` runs the suite against the image on a clean node. `update` installs a
baseline first, upgrades to the image under test, and then runs the same suite
against the upgraded module. It catches what a clean install cannot: a
configuration that a migration drops, an `update-module` that fails, a volume or
a secret that does not survive the version change.

`update` is opt-in, disabled by default. Robot Framework does not fail on an
unused `-v`: a suite that never reads `$SCENARIO` would not error, it would run
the exact install path twice under a different label, doubling the CI cost for
no extra coverage and no visible sign that it happened. Ask for
`scenarios: '["install","update"]'` only once `tests/` has an
`IF '${SCENARIO}' == 'update'` branch to act on it, following the example
below.

The scenario reaches the suite as `-v SCENARIO:install|update`, and the update
leg also gets `-v UPDATE_FROM:<image>`.

`ns8-github-actions` needs no `UPDATE_FROM` because its update leg tests core
modules, which `install.sh` seeds at the stable version. An app module is
installed by its own suite, so the baseline has to be named. Handle it like
this, leaving `UPDATE_FROM` undefined: the CI always passes it, and a manual
`update` run without it fails on a clear "Variable not found" rather than
testing against a baseline nobody chose:

```robot
*** Variables ***
${SCENARIO}       install

*** Test Cases ***
Install the module
    IF    '${SCENARIO}' == 'update'
        ${output}  ${rc} =    Execute Command    add-module ${UPDATE_FROM} 1    return_rc=True
    ELSE
        ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1    return_rc=True
    END
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Global Variable    ${module_id}    ${output.module_id}

Check the module survives the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${rc} =    Execute Command
    ...    api-cli run update-module --data '{"force":true,"module_url":"${IMAGE_URL}","instances":["${module_id}"]}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
```

Configure the module before the update and read the configuration back after
it. That comparison is the coverage the update leg buys.

### Not yet supported: a module bundled into the core

The pattern above is for an app module that installs itself, `add-module`
inside its own suite. `NethServer/ns8-metrics` is shaped differently: `metrics1`
ships as part of the core, under a fixed instance name, with no `add-module`
call anywhere in its suite. Its `install` scenario instead needs the image
under test injected while the core itself is installed:

```yaml
# NethServer/ns8-github-actions, scenario-conditional
coremodules: ${{ matrix.scenario == 'install' && format('ghcr.io/{0}/{1}:{2}', owner, name, tag) || '' }}
```

`install_args` here forwards straight into `install.sh` the same way, but as
one static string for every leg, not conditional on `scenario`. Passing the
image under test through it would make the `install` leg correct and the
`update` leg a no-op: `metrics1` would already be running that image before
`update-module` runs, upgrading it to itself. Leaving it empty makes `install`
test the stock core version instead of the image under test.

Fixing this needs a second input, `install_args_update`, and the same ternary
`args` and `update_from` already use:

```yaml
install_args: ${{ matrix.scenario == 'update' && inputs.install_args_update || inputs.install_args }}
```

Not implemented: no module in this repository's own CI needs it yet, and it
can only be exercised against a real bundled-core module, which none here are.

## The pull request status, comment and their token

Under `workflow_run` the run belongs to the default branch, so the pull request
does not list it. Each leg therefore sets a commit status on the tested commit,
`continuous-integration/qemu/<distro>-<scenario>`, pending while it runs and
then success, failure or error. The pull request shows one line per leg,
linked to the run. That needs `statuses: write`.

The screenshots are uploaded by `cml` and posted as a comment, which needs
`pull-requests: write`.

A called workflow cannot hold more than its caller, so the module's own job
grants both:

```yaml
jobs:
  run:
    permissions:
      contents: read
      pull-requests: write
      statuses: write
```

A NethServer module caller can skip this block when its repository default
workflow permission is `write`, since every job then already holds it. That
also hands a read/write token to every other workflow in the repository, next
to a `workflow_run` chain that checks out and runs the code of a pull request.
Granting it on the one job that needs it is narrower, and it is why this
wrapper asks for the four lines instead of asking you to change a repository
setting.

Without the grant the job still passes: both steps are skipped rather than failing.

## What a suite may rely on

The same on both CI, because both run the same `scripts/test-module.sh`:

| | Value |
|---|---|
| `${NODE_ADDR}` | leader node address |
| `${IMAGE_URL}` | image under test |
| `${SSH_KEYFILE}` | `/tmp/idssh` inside the runner container |
| `${RUN_UI_TESTS}` | `true` or `false` |
| `${SCENARIO}` | `install` or `update` |
| screenshots | `${OUTPUT DIR}/browser/screenshot/N._Name.png` |
| UI gating | `[Tags] ui`, excluded by `--exclude ui` |
| flaky gating | `[Tags] unstable`, tolerated by `--skiponfailure unstable` |
| outputs | `tests/outputs/` in the module tree |

`${UPDATE_FROM}` is the one addition.
