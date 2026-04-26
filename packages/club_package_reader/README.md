# club_package_reader

Archive scanner for Dart package tarballs. Extracts `pubspec.yaml`, `README.md`,
`CHANGELOG.md`, `LICENSE`, example files, and the library list; returns a
`PackageSummary` plus an `ArchiveIssue` list for any validation failure.

This is a **vendored fork** of
[`dart-lang/pub-dev/pkg/pub_package_reader`](https://github.com/dart-lang/pub-dev/tree/master/pkg/pub_package_reader).
Upstream is the authoritative source for "what is a valid pub archive" — we
keep this fork because upstream is published as `publish_to: none` and pins
`resolution: workspace` to the pub-dev monorepo, so it can't be consumed as a
normal pub dependency.

## Using it

```dart
import 'package:club_package_reader/club_package_reader.dart';

final summary = await summarizePackageArchive(
  '/path/to/package.tar.gz',
  policy: ReaderPolicy.club,  // or ReaderPolicy.pubDev for strict mode
);

if (summary.hasIssues) {
  for (final issue in summary.issues) print(issue);
  return;
}
print(summary.pubspecContent);
```

## ReaderPolicy

Pub.dev bakes several assumptions into its validators that don't apply to a
self-hosted private registry. Those assumptions are gated behind
[`ReaderPolicy`](lib/src/policy.dart) rather than removed, so upstream syncs
stay as close to a straight merge as possible.

- `ReaderPolicy.pubDev` — strict defaults, matches upstream.
- `ReaderPolicy.club` — club's defaults. Differences from pub.dev:
  - `LICENSE` file not required
  - `README.md` not required
  - `publish_to` field not rejected
  - Emoji allowed in description
  - Boilerplate Flutter/Dart template descriptions and READMEs accepted

Git-dep rejection and non-default-hosted-dep rejection stay on under both
policies — those are bad for any package repository.

## Syncing with upstream

The upstream source for this fork lives at
`research/pub-dev/pkg/pub_package_reader/` in this repo (snapshotted for easy
diffing). To pull a newer upstream revision:

1. Refresh the snapshot:
   ```
   rm -rf research/pub-dev
   git clone --depth=1 https://github.com/dart-lang/pub-dev.git research/pub-dev
   ```
2. Diff the trees:
   ```
   diff -r research/pub-dev/pkg/pub_package_reader packages/club_package_reader
   ```
3. Apply the upstream changes. Our local modifications are deliberately small:
   - [lib/club_package_reader.dart](lib/club_package_reader.dart) — adds a
     `ReaderPolicy policy` parameter to `summarizePackageArchive` and gates
     the license/readme/publish_to/git-dep/template/emoji checks behind it.
     `forbidGitDependencies` gained `allowGit` + `forbidNonDefaultHosted`
     params. `validateDescription` gained an optional `policy` param.
     `validateNewPackageName` was simplified (no mixed-case tables).
   - [lib/src/policy.dart](lib/src/policy.dart) — new file. Policy knobs.
   - [lib/src/names.dart](lib/src/names.dart) — dropped the legacy mixed-case
     package tables. Kept regexes, reserved words, and invalid-host-names.
   - Package name (`pub_package_reader` → `club_package_reader`) in
     imports/exports across every file.
4. Run `dart test --concurrency=1` in this package — all tests must pass.
5. Record the upstream commit SHA you synced from in the next commit message.
