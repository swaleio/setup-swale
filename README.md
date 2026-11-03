# Setup Swale CLI

Installs the [Swale CLI](https://docs.swale.io/reference/install-cli) in a GitHub Actions workflow and adds `swale` to the `PATH`:

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: swaleio/setup-swale@v1
  - run: swale push my-project/my-repo --path ./dist
    env:
      SWALE_ACCOUNT_NAME: ${{ vars.SWALE_ACCOUNT_NAME }}
      SWALE_ACCOUNT_TOKEN: ${{ secrets.SWALE_ACCOUNT_TOKEN }}
```

It runs on Linux, macOS and Windows runners, x64 and arm64, and in container jobs, Alpine included.

## Inputs

| Input     | Default  | Description                                                     |
| --------- | -------- | --------------------------------------------------------------- |
| `version` | `latest` | The Swale CLI version to install, such as `1.0.1`, or `latest`. |

## Outputs

| Output    | Description                                    |
| --------- | ---------------------------------------------- |
| `version` | The Swale CLI version installed.               |
| `path`    | The full path of the installed `swale` binary. |

## Signing in

The action installs the CLI and doesn't sign in. The CLI reads its account and a personal access token from `SWALE_ACCOUNT_NAME` and `SWALE_ACCOUNT_TOKEN`, so set them on the steps or the job that run `swale`, from a variable and a secret, as above. See the [CLI reference](https://docs.swale.io/reference/cli-reference#environment-variables).

## What it checks

Before installing, the action verifies the release's signed manifest:

1. The manifest must be signed by Swale's signing key, which is fetched from swale.io and must have the fingerprint `F52CF38130C597453BE6BD7DD65BF0C473F6E965`, and the key must not be revoked. A signature by a subkey that has since expired still counts, so an older release keeps installing after the key is rotated.
2. For a pinned `version`, the manifest must name that version.
3. The binary's SHA-256 must match the manifest's.

If any check fails, or `gpg` isn't installed, the step fails and installs nothing. GitHub's hosted runners have `gpg`. In a container job, install it first, along with `curl` or `wget` if the image has neither: `apk add gnupg` on Alpine, or `apt-get update && apt-get install -y ca-certificates curl gnupg` on Debian or Ubuntu.

## Versions

`swaleio/setup-swale@v1` follows the newest 1.x release of the action: when a release is published, an approved workflow moves `v1` to it. To pin the action exactly, use a release tag such as `@v1.0.0`, whose releases are immutable, or a commit SHA. A [workflow dependency lockfile](https://docs.github.com/en/actions/concepts/security/workflow-dependency-lockfiles) records the commit for you.

The action's version is separate from the CLI's: the `version` input picks the CLI.
