# club — CLI Tool

The `club` CLI is a Dart command-line tool for authenticating with a club
server and publishing packages. API key management lives in the web
dashboard — the CLI only *consumes* keys the dashboard mints.

---

## Installation

```bash
# Install globally from the club repository
dart pub global activate club_cli

# Or from your club server (once published)
dart pub global activate club_cli --hosted-url https://club.example.com
```

---

## Quick Start

```bash
# 1. Login to your club server
club login https://club.example.com

# 2. Configure dart pub to use your server
club setup

# 3. Publish a package
cd my_package/
club publish

# 4. Use packages in your project
# Add to pubspec.yaml:
#   dependencies:
#     my_package:
#       hosted: https://club.example.com
#       version: ^1.0.0
dart pub get
```

---

## Commands

### club login

Authenticate with a club server. Supports two modes: interactive
email/password, or non-interactive with a dashboard-minted API key.

```
club login <server-url> [--email <email>] [--password <password>]
club login <server-url> --key <club_pat_...>
```

**Arguments:**
- `<server-url>` — The club server URL (e.g., `https://club.example.com`)

**Options:**
- `--email` — Email address (prompted if not provided)
- `--password` — Password (prompted with hidden input if not provided)
- `--key` — An API key minted in the web dashboard under **Settings → API keys**. Alternatively, set the `CLUB_TOKEN` env var.

**Behavior:**
1. With `--key`, validates the key against the server and stores it locally
2. Otherwise, prompts for email and password and calls `POST /api/auth/login`
3. Stores credentials in `~/.config/club/credentials.json`
4. Sets this server as the default

**Examples:**
```bash
# Interactive login
$ club login https://club.example.com
Email: jane@example.com
Password: ********
Logged in as jane@example.com

# Non-interactive login with a dashboard key
$ club login https://club.example.com --key club_pat_x9y8z7w6...
Logged in with API key (CI - GitHub Actions)
```

---

### club logout

Remove stored credentials for a server.

```
club logout [--server <url>] [--all]
```

**Options:**
- `--server` — Server URL to logout from (default: current default server)
- `--all` — Remove credentials for all servers

**Example:**
```bash
$ club logout
Logged out from https://club.example.com
```

---

### API key management

API keys are created, listed, and revoked in the web dashboard at
**Settings → API keys**. There is no CLI command for managing keys.

On the CLI, consume a dashboard-minted key by passing it to `club login
--key <club_pat_...>` or by setting the `CLUB_TOKEN` environment
variable. See [club login](#club-login) above.

---

### club config

Show or update CLI configuration.

```
club config                     # Show current config
club config set-server <url>    # Set default server
club config show                # Alias for: club config
```

**Example:**
```bash
$ club config
Default server: https://club.example.com
Logged in as:   jane@example.com
Credentials:    ~/.config/club/credentials.json

Configured servers:
  https://club.example.com (default)
  https://staging.club.example.com
```

---

### club setup

Configure `dart pub` to work with your club server. This is the key
integration command.

```
club setup [--server <url>] [--env-var <VAR_NAME>]
```

**Options:**
- `--server` — Server URL (default: current default server)
- `--env-var` — Use environment variable for the token instead of storing it directly

**What it does:**
1. Retrieves the stored token for the server
2. Runs `dart pub token add <server-url>` to register the token in dart pub's credential store
3. Prints instructions for adding packages to `pubspec.yaml`

**Example:**
```bash
$ club setup
Configuring dart pub for https://club.example.com...
Token registered with dart pub.

To use packages from club, add to your pubspec.yaml:

  dependencies:
    my_package:
      hosted: https://club.example.com
      version: ^1.0.0

Or set PUB_HOSTED_URL to use club as the default:

  export PUB_HOSTED_URL=https://club.example.com
```

**CI/CD Setup with Environment Variable:**
```bash
$ club setup --env-var CLUB_TOKEN
Configuring dart pub for https://club.example.com...
Running: dart pub token add https://club.example.com --env-var CLUB_TOKEN

To use in CI/CD, set the CLUB_TOKEN environment variable to your API token.
```

---

### club publish

Publish the current package to the club server.

```
club publish [--server <url>] [--dry-run] [--force]
```

**Options:**
- `--server` — Target server URL (default: reads `publish_to` from pubspec.yaml, or default server)
- `--dry-run` — Validate without actually publishing
- `--force` — Skip confirmation prompt

**Behavior:**
Wraps `dart pub publish` with the correct server URL:
1. Reads `publish_to` from `pubspec.yaml` if set
2. Falls back to the default server from club config
3. Sets `PUB_HOSTED_URL` and runs `dart pub publish`

**Example:**
```bash
$ cd my_package/
$ club publish
Publishing my_package 1.2.0 to https://club.example.com...

Package has 0 warnings.
Do you want to publish my_package 1.2.0? [y/N]: y

Uploading...
Successfully uploaded my_package version 1.2.0.
```

---

### club admin user list

List all users on the server (admin only).

```
club admin user list [--page <n>]
```

**Example:**
```bash
$ club admin user list
┌──────────────┬─────────────────────┬───────┬────────┐
│ ID           │ Email               │ Admin │ Active │
├──────────────┼─────────────────────┼───────┼────────┤
│ 550e8400...  │ admin@example.com   │ yes   │ yes    │
│ 7c9e6a10...  │ jane@example.com    │ no    │ yes    │
│ a3b4c5d6...  │ bob@example.com     │ no    │ yes    │
└──────────────┴─────────────────────┴───────┴────────┘
```

---

### club admin user create

Create a new user account (admin only).

```
club admin user create --email <email> [--password <pass>] [--name <name>] [--admin]
```

**Options:**
- `--email` — User email (required)
- `--password` — Initial password (prompted if not provided)
- `--name` — Display name
- `--admin` — Grant admin privileges

---

### club admin user disable

Disable a user account (admin only).

```
club admin user disable <user-id>
```

---

### club admin package list

List all packages (admin only).

```
club admin package list [--page <n>]
```

---

### club admin package moderate

Moderate a package (admin only).

```
club admin package moderate <package> --action <discontinue|delete>
```

---

## Credential Storage

### File Location

| Platform | Path |
|----------|------|
| Linux / macOS | `~/.config/club/credentials.json` |
| Windows | `%APPDATA%\club\credentials.json` |

### File Format

```json
{
  "defaultServer": "https://club.example.com",
  "servers": {
    "https://club.example.com": {
      "token": "club_a1b2c3d4e5f6...",
      "email": "jane@example.com",
      "createdAt": "2026-04-09T10:00:00.000Z"
    },
    "https://staging.club.example.com": {
      "token": "club_x9y8z7w6...",
      "email": "jane@example.com",
      "createdAt": "2026-04-09T11:00:00.000Z"
    }
  }
}
```

### Security

- File permissions: `chmod 600` on Unix (owner read/write only)
- Tokens are stored in plaintext (same as `~/.pub-cache/credentials.json`)
- For CI/CD, use `--env-var` with `club setup` to avoid storing tokens on disk

---

## dart pub Integration

### How it works

The `dart pub` client (since Dart 2.19) supports custom package repositories
with token-based authentication.

**Step 1: Register token**
```bash
# Done automatically by 'club setup'
dart pub token add https://club.example.com
```

This stores the token in `~/.pub-cache/credentials.json`:
```json
{
  "hosted": [
    {
      "url": "https://club.example.com",
      "token": "club_a1b2c3d4..."
    }
  ]
}
```

**Step 2: Use in pubspec.yaml**
```yaml
dependencies:
  # Per-package hosted URL
  my_package:
    hosted: https://club.example.com
    version: ^1.0.0

  # Or use the short form
  my_package:
    hosted:
      name: my_package
      url: https://club.example.com
    version: ^1.0.0
```

**Step 3: Resolve and download**
```bash
dart pub get
# dart pub automatically sends Authorization: Bearer <token>
# to https://club.example.com for matching hosted URLs
```

### Alternative: PUB_HOSTED_URL

Set `PUB_HOSTED_URL` to use club as the default package repository for
**all** packages (overrides pub.dev):

```bash
export PUB_HOSTED_URL=https://club.example.com
dart pub get
```

This is useful when all your dependencies come from club. For mixed
setups (some from pub.dev, some from club), use per-package `hosted` URLs.

### Publishing

Set `publish_to` in your package's `pubspec.yaml`:

```yaml
name: my_package
version: 1.2.0
publish_to: https://club.example.com
```

Then publish:
```bash
dart pub publish
# Or use the club wrapper:
club publish
```

### CI/CD Integration

**GitHub Actions example:**
```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1

      - name: Configure club token
        run: dart pub token add https://club.example.com --env-var CLUB_TOKEN
        env:
          CLUB_TOKEN: ${{ secrets.CLUB_TOKEN }}

      - name: Publish
        run: dart pub publish --force
```

**GitLab CI example:**
```yaml
publish:
  image: dart:stable
  script:
    - dart pub token add https://club.example.com --env-var CLUB_TOKEN
    - dart pub publish --force
  variables:
    CLUB_TOKEN: $CLUB_TOKEN
```

---

## Package Structure

```
packages/club_cli/
├── bin/
│   └── club.dart              # Entry point → CommandRunner
├── lib/
│   ├── src/
│   │   ├── commands/
│   │   │   ├── login_command.dart
│   │   │   ├── logout_command.dart
│   │   │   ├── token_command.dart      # Parent: list, create, revoke
│   │   │   ├── config_command.dart
│   │   │   ├── publish_command.dart
│   │   │   ├── setup_command.dart
│   │   │   └── admin/
│   │   │       ├── admin_command.dart
│   │   │       ├── user_command.dart
│   │   │       └── package_command.dart
│   │   ├── credentials.dart            # Token file read/write
│   │   ├── config.dart                 # CLI config management
│   │   └── pub_integration.dart        # dart pub token add wrappers
│   └── club_cli.dart                  # CommandRunner setup
├── pubspec.yaml
└── test/
```

### Dependencies

```yaml
dependencies:
  args: ^2.5.0
  club_api: ^1.0.0       # Client SDK — all server communication
  path: ^1.9.0
  io: ^1.0.4              # stdin with no echo for password input
```

**Note:** `club_cli` uses `club_api` (the client SDK) for all server
communication. It does NOT make raw HTTP calls. This means:
- All HTTP logic is in one place (`club_api`)
- The CLI and any custom user tooling share the same client code
- Bug fixes in the client SDK benefit both the CLI and user scripts

See [CLIENT_SDK.md](CLIENT_SDK.md) for the `club_api` package documentation.
