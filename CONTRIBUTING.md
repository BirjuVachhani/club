# Contributing to club

Thanks for your interest. club is pre-1.0 — APIs, schemas, and internals
are still in motion. That means:

- Small, focused PRs are much easier to merge than sweeping refactors.
- If you're planning anything non-trivial, **open an issue first** so we
  can agree on direction before you spend time on a patch.
- Expect reviews to push back on scope. "Do one thing well" is the rule.

## Quick start

```bash
git clone https://github.com/BirjuVachhani/club.git
cd club
dart pub get

# Generate code (club_core only)
cd packages/club_core && dart run build_runner build --delete-conflicting-outputs && cd -

# Run the server locally
SERVER_URL=http://localhost:8080 \
JWT_SECRET=dev-secret-at-least-32-characters-long-for-testing \
ADMIN_EMAIL=admin@localhost \
ADMIN_PASSWORD=admin \
SQLITE_PATH=/tmp/club-dev.db \
BLOB_PATH=/tmp/club-dev-packages \
dart run packages/club_server/bin/server.dart
```

Full dev environment setup, including the SvelteKit frontend and
end-to-end test runner, lives in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Before you open a PR

- `dart analyze` is clean across every package.
- Any new public API has a dartdoc comment.
- Tests cover the new path. Integration tests hit real SQLite, not mocks.
- If you touched models in `club_core`, rerun the json_serializable build
  step above and commit the regenerated files.
- Commit messages: short imperative summary + context in the body.
  Conventional-commit prefixes (`feat:`, `fix:`, `chore:`) are welcome
  but not required.

## Scope of contributions we're looking for

Good first patches:

- Bug fixes with a failing test.
- Docs corrections, typo fixes, clearer error messages.
- Additional storage backends (S3-compatible, GCS, Azure Blob).
- Validator coverage gaps in the CLI publish flow.

Please **ask before starting** if you want to:

- Add a new top-level package to the workspace.
- Change the database schema or migration format.
- Swap out a core dependency (shelf, drift, bcrypt, etc.).
- Add a new auth scheme or change the token format.

## Code style

- Follow the analyzer settings in [analysis_options.yaml](analysis_options.yaml).
- Prefer explicit types on public APIs; `var` is fine for locals.
- Keep comments scarce — explain *why* when it's non-obvious, not *what*.
- No generated files outside `*.g.dart`.

## Reporting bugs

Open a GitHub issue with:

- club version (`club --version` or commit SHA).
- OS / arch / Dart SDK version.
- Steps to reproduce. A minimal pubspec and the exact command you ran
  beats a prose description every time.

Security issues: **don't** open a public issue. See [SECURITY.md](SECURITY.md).

## License

By submitting a PR, you agree that your contribution is licensed under
the [Apache License 2.0](LICENSE), same as the rest of the project.
Section 5 of the license makes this implicit for any PR — no CLA to sign.
