# setup-club

A GitHub Action that installs the [club](https://club.birju.dev) CLI and
configures the Dart toolchain to authenticate against a self-hosted club
package registry.

After this action runs:

- `club` is on `PATH` for subsequent steps.
- `dart pub get` and `dart pub publish` work against your private registry —
  the token is read from `CLUB_TOKEN` at request time, never written to disk.
- `club publish`, `club whoami`, etc. also work, since the CLI reads
  `CLUB_TOKEN` from the environment.

## Prerequisites

The action does not install the Dart SDK. Run `dart-lang/setup-dart` first.

## Usage

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1

      - uses: BirjuVachhani/club/actions/setup-club@v1
        with:
          server: https://packages.example.com
          token: ${{ secrets.CLUB_TOKEN }}

      - run: dart pub get
      - run: dart pub publish --force
```

## Inputs

| Input                  | Required | Default  | Description                                                                                       |
| ---------------------- | :------: | -------- | ------------------------------------------------------------------------------------------------- |
| `server`               |    yes   |          | club server URL, e.g. `https://packages.example.com`.                                             |
| `token`                |    yes   |          | A `club_pat_...` token. Pass via `secrets`.                                                       |
| `version`              |    no    | `latest` | Specific CLI release tag to install, e.g. `0.1.0`.                                                |
| `set-default-registry` |    no    | `false`  | When `true`, exports `PUB_HOSTED_URL=<server>` so club becomes the default registry for `dart pub`. |

## Environment exported to subsequent steps

| Variable         | Value                                                    |
| ---------------- | -------------------------------------------------------- |
| `CLUB_TOKEN`     | The token (masked in logs).                              |
| `PUB_HOSTED_URL` | The server URL — only when `set-default-registry: true`. |

## How it works

1. Verifies `dart` is on `PATH` (fails with a clear error otherwise).
2. Downloads `install.sh` (Unix) or `install.ps1` (Windows) from
   `club.birju.dev`, which fetches the matching release archive from
   GitHub, verifies its SHA256, and installs the binary.
3. Runs `dart pub token add <server> --env-var CLUB_TOKEN` so the Dart
   toolchain reads the token from the environment at request time.
4. Exports `CLUB_TOKEN` (and optionally `PUB_HOSTED_URL`) to
   `$GITHUB_ENV` for subsequent steps.
