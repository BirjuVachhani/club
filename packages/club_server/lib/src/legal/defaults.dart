/// Default legal copy shipped with the CLUB software.
///
/// These defaults are rendered whenever the operator has not published
/// a customised version via the admin UI. They are written to be
/// neutral and accurate for *any* CLUB deployment: CLUB is self-hosted,
/// each instance operator is the actual data controller / contracting
/// party, and the operator can override this content at any time by
/// saving their own markdown through `/admin/settings/legal`.
///
/// These strings are the single source of truth for the default
/// content. They are served by the public legal API and used by the
/// admin editor as the baseline "reset to default" payload.
library;

/// Privacy Policy — markdown.
const String defaultPrivacyMarkdown = '''
# Privacy Policy

CLUB is open-source software for hosting a private Dart and Flutter
package repository. Each CLUB instance is operated independently.
This page describes the privacy characteristics that apply to the
CLUB software itself. The operator of *this* instance is the data
controller for any personal information processed here, and may
publish a supplemental policy that takes precedence over this default
notice.

## 1. Who we are

"CLUB" refers to the open-source software project. "This instance,"
"we," and "us" refer to the organization or individual operating the
deployment you are interacting with now. If you are unsure who that
is, reach out to the administrator who invited you.

## 2. Information the software stores

A CLUB instance stores only what is required to run a package
repository and manage access to it:

- **Account details.** Email address, display name, optional avatar,
  role, and a bcrypt hash of your password. Raw passwords are never
  stored.
- **Authentication artifacts.** Browser sessions and personal access
  tokens are stored as SHA-256 hashes. For each active session we
  retain the creation time, last-used time, expiry, and the
  user-agent and IP address observed at the time the session was
  created, so you can review and revoke sessions yourself.
- **Content you publish.** Package tarballs, their pubspec metadata,
  READMEs, changelogs, and any publisher information you attach.
  This content is stored on the infrastructure the operator runs.
- **Activity on the instance.** Package likes, publish events, and
  an administrative audit log (who created a user, who revoked a
  token, and similar events). The audit log exists so instance
  operators can reason about security, not to profile users.
- **Usage counts.** Aggregate, non-identifying download counts per
  package version, to power the package browser. No per-user
  download history is retained.

## 3. Information the software does *not* collect

The CLUB software ships without third-party analytics, advertising
trackers, or behavioural profiling. It does not embed external
scripts or pixels. It does not transmit data to the CLUB project
maintainers. Cookies are limited to what is needed for authentication
and UI preferences (theme).

If the operator of this instance has added integrations (for example,
an error reporting service or an SSO provider), those integrations
will be disclosed in the operator's own policy.

## 4. Where data lives

A default CLUB deployment stores metadata in a local SQLite database
and package tarballs on the local filesystem. Some operators
configure alternative blob or database backends via environment
variables. In every case the data is held by the operator — not by
the CLUB project or any CLUB-branded service.

## 5. How data is used

The instance uses stored data to authenticate you, display packages
and publishers, enforce access controls, serve your content to
authorized clients (such as the `dart pub` command), and let
administrators investigate security issues. We do not sell or rent
personal information, and the software does not share it with third
parties by default.

## 6. What is visible to others

On this instance, information you publish — package names and
versions, pubspec metadata, README, changelog, publisher name and
description, and your public display name when you publish or like a
package — is visible to every account that can reach the instance.
Some deployments are public; others are behind VPN or SSO. Ask your
operator about the visibility model before publishing anything
sensitive.

## 7. Retention

Account records are retained for as long as your account exists.
Session tokens expire automatically. Audit log entries are kept for
the period chosen by the operator. Package versions typically persist
indefinitely so that dependent projects remain reproducible;
operators may define a retirement policy for versions that need to be
withdrawn.

## 8. Your choices

You can update your display name and avatar, rotate your password,
review active sessions, and revoke personal access tokens from your
account settings at any time. To exercise any other data right —
access, correction, export, or deletion — please contact the
administrator of this instance. Because CLUB is self-hosted, we
cannot action requests that belong to a different deployment.

## 9. Security

CLUB stores credentials as bcrypt hashes and API tokens as SHA-256
hashes. Browser sessions use rotating, short-lived cookies backed by
a server-side record that can be revoked. Operators are expected to
terminate TLS in front of the server and keep backups. No system is
perfectly secure; if you believe you have found a vulnerability in
the CLUB software itself, please report it through the project's
public repository so it can be fixed for every deployment.

## 10. Children

CLUB is a developer tool and is not directed to children under 13
(or the equivalent minimum age in your jurisdiction). Operators
should not knowingly create accounts for them.

## 11. Changes to this policy

The default policy that ships with the software may evolve as the
project changes. Operators may amend or replace it at any time. When
material changes are made on this instance, the "Last updated" date
at the top of this page will change; significant updates will be
announced to active accounts where possible.

## 12. Contact

Questions about data held on this instance should go to the
administrator who operates it. Questions about the CLUB software
itself belong in the project's public issue tracker.
''';

/// Terms of Use — markdown.
const String defaultTermsMarkdown = '''
# Terms of Use

CLUB is open-source software that lets an organization host its own
Dart and Flutter package repository. These default Terms of Use
describe a reasonable baseline for using any CLUB instance. The
operator of *this* instance may publish supplemental terms; where
those conflict with these defaults, the operator's terms control.

## 1. Who the agreement is with

By creating an account or otherwise using this instance, you enter
into an agreement with the organization or individual who operates it
— not with the CLUB open-source project. The CLUB project maintainers
provide the software under the Apache License 2.0 and are not a party
to this agreement.

## 2. Accounts

To publish or manage packages you need an account on this instance.
You are responsible for the accuracy of the information you provide
and for keeping your password and any personal access tokens
confidential. Tell the instance administrator promptly if you believe
your account has been compromised.

Sharing credentials, operating someone else's account without
permission, or circumventing access controls is not allowed.

## 3. Acceptable use

You agree not to use this instance to:

- publish malware, cryptominers, or packages whose primary function
  is to harm systems, exfiltrate data, or obscure their behaviour;
- infringe someone else's intellectual property, trade secrets, or
  privacy, or publish content you do not have the right to
  distribute;
- upload content that is illegal in the operator's jurisdiction;
- harass other users, impersonate a real person or organization, or
  misrepresent package ownership;
- interfere with the instance's availability — for example, by
  abusive automation, attempts to overwhelm the server, or probing
  for vulnerabilities without authorization.

Responsible security research on the CLUB software is welcome through
the project's public repository. Testing against a live instance you
do not own requires that operator's permission.

## 4. Content you publish

You retain ownership of every package you upload. By publishing a
version, you grant the operator of this instance the rights necessary
to host the package and serve it to the users and client tools (such
as `dart pub`) that the operator has authorized to access the
instance. That grant continues for as long as the version remains
published, and extends to reasonable operational activities such as
backups, mirroring between the operator's own systems, and indexing.

Every package you publish must carry a license that permits the
distribution described above. For packages intended to be public, a
recognized open-source license (such as MIT, BSD, or Apache 2.0) is
expected. For private or proprietary packages on a restricted-access
instance, an internal licensing statement is acceptable provided it
does not conflict with the usage your team actually needs.

You are responsible for the content of your packages, including any
bundled dependencies and assets. Do not include secrets, API keys,
personal data, or credentials in a published package — once
distributed, they should be considered compromised.

## 5. Unpublishing and removal

The pub ecosystem prefers immutable releases so that dependent
projects remain reproducible. An instance administrator may, however,
retract or remove a version that violates these terms, contains
disclosed secrets, or was published in error. Where possible,
operators should retract rather than delete so that existing lockfiles
keep resolving.

## 6. Availability and changes

The instance is provided on an as-available basis. The operator may
change features, upgrade the CLUB software, perform maintenance, or
discontinue the service, with reasonable notice where practical.
Neither the operator nor the CLUB maintainers guarantee that the
service will be error-free or continuously available.

## 7. Intellectual property in the software

The CLUB software is distributed under the Apache License 2.0. That
license governs your rights to the code itself if you obtain it for
your own deployment. These Terms of Use govern your use of *this*
hosted instance and are separate from the software license.

## 8. Third-party dependencies

Packages you download from this instance may themselves include
third-party code under their own licenses. Review those licenses
before relying on a package. The operator is not responsible for the
contents of user-uploaded packages.

## 9. Disclaimer

To the maximum extent permitted by law, the service is provided "as
is" and "as available," without any warranty — express or implied —
of merchantability, fitness for a particular purpose, or
non-infringement. The operator does not warrant that any given
package or version will meet your requirements or be free of defects.

## 10. Limitation of liability

To the maximum extent permitted by law, neither the instance operator
nor the CLUB maintainers will be liable for indirect, incidental,
special, consequential, or punitive damages, or for lost profits,
revenues, data, or goodwill, arising out of or in connection with
your use of the service. This section does not limit liability that
cannot be excluded under applicable law.

## 11. Termination

You may stop using the instance and ask the administrator to delete
your account at any time. The administrator may suspend or terminate
an account that violates these terms or poses a security risk.
Content that other users depend on (such as published package
versions) may persist after your account is removed so that builds
continue to resolve.

## 12. Governing law

Unless the instance operator has specified otherwise, these terms are
governed by the laws of the operator's place of business, without
regard to its conflict-of-laws rules. Nothing in these terms overrides
consumer-protection rights you may have in your own jurisdiction.

## 13. Changes

The default terms that ship with the software may evolve as the
project changes, and operators may amend their supplemental terms at
any time. When material changes are made on this instance, the "Last
updated" date at the top of this page will change; significant
updates will be announced to active accounts where possible.

## 14. Contact

Questions about these terms should go to the administrator of this
instance. Questions about the CLUB software itself belong in the
project's public issue tracker.
''';
