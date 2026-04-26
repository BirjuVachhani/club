# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/BirjuVachhani/club/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill out the form with as much detail as you can.

If private reporting isn't available to you for some reason, email the
maintainer directly via the address on the [GitHub profile](https://github.com/BirjuVachhani).

## What to include

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected versions, if known.
- Any suggested fix or mitigation.

## Response

club is a small project. Expect:

- An acknowledgement within **72 hours**.
- An initial assessment within **7 days**.
- A coordinated disclosure once a fix is available — we'll credit you in
  the release notes unless you prefer to stay anonymous.

## Supported versions

Only the latest tagged release receives security fixes for now. Once
club reaches 1.0, we'll publish a longer support window here.

## Scope

In scope:

- The server, CLI, client SDK, and web frontend in this repository.
- The published Docker image at `ghcr.io/birjuvachhani/club`.
- The default storage, database, and auth code paths.

Out of scope:

- Self-hosted deployments misconfigured by the operator (e.g. a weak
  `JWT_SECRET`, a publicly exposed admin setup endpoint left open past
  first-run, a reverse proxy that strips TLS).
- Vulnerabilities in third-party dependencies — please report those
  upstream. We'll still fix them here once an upstream patch lands.
- Social engineering, physical attacks, or issues requiring a compromised
  host.
