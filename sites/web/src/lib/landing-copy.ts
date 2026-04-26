// Shared copy bank for landing-page explorations (/dev/landing/*).
// Features are written in user language, benefit-first. Edit here and
// every approach picks the change up.

export const PITCH = {
  name: "CLUB",
  oneLiner: "Your private pub.dev.",
  elevator:
    "CLUB is an open-source, self-hostable alternative to pub.dev — a private Dart and Flutter package repository you run on your own infrastructure.",
  workflow:
    "It speaks the full Pub Spec v2 API, so the commands your team already uses — dart pub get, dart pub add, dart pub publish — work unchanged. Point them at your CLUB server and keep shipping.",
  ownership:
    "Nothing leaves your walls. No tracking, no ads, no third-party data. You decide who publishes, who reads, and when to pull a version off the shelf.",
};

export type Feature = {
  key: string; // short eyebrow label
  title: string; // short headline
  body: string; // 1–2 sentence benefit-led description
  group: "workflow" | "team" | "quality" | "control" | "infra";
};

export const FEATURES: Feature[] = [
  // Workflow — "same commands, your server"
  {
    key: "Familiar",
    title: "Works with dart pub, unchanged",
    body: "Your team keeps running the commands they already know. dart pub get, dart pub add, dart pub publish — all work, just pointed at your CLUB server.",
    group: "workflow",
  },
  {
    key: "CLI",
    title: "A CLI of its own",
    body: "Log in, publish, add dependencies, manage publishers, and run admin tasks from one club CLI. Pairs with dart pub, doesn't replace it.",
    group: "workflow",
  },
  {
    key: "CI / CD",
    title: "CI-ready out of the box",
    body: "Use the club CLI in any pipeline. A first-party GitHub Action is included for publishing and installing packages from CI.",
    group: "workflow",
  },

  // Team — "who gets to do what"
  {
    key: "Publishers",
    title: "Publishers like pub.dev",
    body: "Organize packages under publishers your team owns — verified or unverified. Manage membership, transfer ownership, and keep scopes clean.",
    group: "team",
  },
  {
    key: "Roles",
    title: "Admin · Editor · Viewer",
    body: "Three roles, clear boundaries. Admins run the show, editors publish and curate, viewers can browse and download — audit-friendly by default.",
    group: "team",
  },
  {
    key: "Uploaders",
    title: "Named uploaders per package",
    body: "Grant CI tokens per package, not per account. Rotate without touching humans, revoke anytime — who uploaded what is always clear.",
    group: "team",
  },

  // Quality — "browse it, score it, find it"
  {
    key: "Web UI",
    title: "A web platform people enjoy using",
    body: "Clean package pages, READMEs and changelogs with full markdown, syntax highlighting, and everything you'd expect from pub.dev — on your server.",
    group: "quality",
  },
  {
    key: "Scoring",
    title: "Pub scoring on par with pub.dev",
    body: "The same quality, maintenance, and popularity signals — calculated on your packages, inside your walls.",
    group: "quality",
  },
  {
    key: "Dartdoc",
    title: "Auto-hosted API reference",
    body: "Publish a package and get a generated dartdoc API reference rendered and hosted alongside the README — no extra pipeline to run.",
    group: "quality",
  },
  {
    key: "Search",
    title: "Full-text search that keeps up",
    body: "Find packages by name, description, or README content in milliseconds. Stays fast as the registry grows into the thousands.",
    group: "quality",
  },
  {
    key: "Likes",
    title: "Likes, favorites, trends",
    body: "Your team can favorite packages and see what's getting used. A gentle social layer for an internal registry.",
    group: "quality",
  },
  {
    key: "Analytics",
    title: "Downloads & traffic dashboard",
    body: "Daily, weekly, and monthly download matrices for every package — plus a stats dashboard for users, publishers, and traffic at a glance.",
    group: "quality",
  },

  // Control — "you own this thing"
  {
    key: "Control",
    title: "Unlist, discontinue, retract, delete",
    body: "Full lifecycle control over every version. Mis-publish something sensitive? Fix it. Deprecate a package? Do it. You're actually in charge.",
    group: "control",
  },
  {
    key: "Overwrite",
    title: "Force-overwrite a version",
    body: "Sometimes a published tarball is just wrong. CLUB lets you replace a version in place when you need to — with auditability.",
    group: "control",
  },
  {
    key: "Transfers",
    title: "Clean ownership transfers",
    body: "Move packages between publishers as teams and projects change. No database surgery, no tickets to the provider.",
    group: "control",
  },
  {
    key: "Privacy",
    title: "No tracking, no ads, ever",
    body: "There is no telemetry. No analytics pixels. No third-party SDKs. It's open source — audit the code and see.",
    group: "control",
  },
  {
    key: "Legal",
    title: "Your privacy and terms",
    body: "Drop in your own privacy and terms pages and they wire up across the UI automatically. Make it look like your company because it is.",
    group: "control",
  },

  // Infra — "how it runs"
  {
    key: "Storage",
    title: "Storage you already use",
    body: "Filesystem for dev. S3 or Firebase Storage (GCS) for prod. Pick a backend with an env var — no code changes.",
    group: "infra",
  },
  {
    key: "Docker",
    title: "One container, two architectures",
    body: "A single Docker image ships the server, the web UI, and dartdoc. Multi-arch: linux/amd64 and linux/arm64. Reverse-proxy notes included.",
    group: "infra",
  },
  {
    key: "Docs",
    title: "Documentation for everything",
    body: "From docker run to reverse-proxy setup, CLI install, CI integration, and API reference — the docs cover the whole path.",
    group: "infra",
  },
];

// Convenience lookups
export const byGroup = (g: Feature["group"]) => FEATURES.filter((f) => f.group === g);

export const GROUP_LABELS: Record<Feature["group"], { eyebrow: string; title: string; sub: string }> = {
  workflow: {
    eyebrow: "Publish & install",
    title: "The commands your team already knows",
    sub: "CLUB plugs into the workflow dart and flutter developers already have. Point `hosted:` at your server and every command keeps working.",
  },
  team: {
    eyebrow: "Teams & access",
    title: "Who gets to publish, who gets to see",
    sub: "Organize packages under publishers. Give people roles that match their job. Grant CI tokens that expire when you say so.",
  },
  quality: {
    eyebrow: "Discover & trust",
    title: "A registry you enjoy browsing",
    sub: "A clean web UI, real search, the same pub scoring engine, and auto-generated API docs — everything discovery needs, on your server.",
  },
  control: {
    eyebrow: "You are the admin",
    title: "Everything you can't do on pub.dev",
    sub: "Unlist a version. Retract a mis-publish. Transfer a package. Delete what you don't need. It's your registry — act like it.",
  },
  infra: {
    eyebrow: "Run it anywhere",
    title: "One container, your hardware",
    sub: "A single multi-arch Docker image with the server, the web UI, and docs generation bundled in. Swap storage with an env var.",
  },
};

// ─── FAQs ─────────────────────────────────────────────────────────
// Used by /dev/faq explorations and the FAQ block on the final landing.
// Categories double as filter tabs in some variants.

export type FaqCategory = "basics" | "workflow" | "control" | "deploy" | "trust";

export type Faq = {
  q: string;
  a: string;
  cat: FaqCategory;
};

export const FAQ_CATEGORIES: Record<FaqCategory, { label: string; eyebrow: string }> = {
  basics:   { label: "Basics",          eyebrow: "What it is" },
  workflow: { label: "Workflow",        eyebrow: "Day to day" },
  control:  { label: "Admin & control", eyebrow: "Your registry" },
  deploy:   { label: "Run it",          eyebrow: "Deploy & ops" },
  trust:    { label: "Trust",           eyebrow: "Privacy & licensing" },
};

export const FAQS: Faq[] = [
  // Basics
  {
    cat: "basics",
    q: "What exactly is CLUB?",
    a: "CLUB is an open-source, self-hosted <a href='https://dart.dev'>Dart</a> and <a href='https://flutter.dev'>Flutter</a> package repository. It implements the full Pub Spec v2 API, so any client that talks to <a href='https://pub.dev'>pub.dev</a> — including dart pub itself — works against your CLUB server unchanged.",
  },
  {
    cat: "basics",
    q: "How is this different from <a href='https://pub.dev'>pub.dev</a>?",
    a: "<a href='https://pub.dev'>pub.dev</a> is the public <a href='https://dart.dev'>Dart</a> registry, run by the <a href='https://dart.dev'>Dart</a> team. CLUB is software you run yourself. Same shape, your hardware, your packages, your rules. You can use both at once: public deps from <a href='https://pub.dev'>pub.dev</a>, private deps from CLUB.",
  },
  {
    cat: "basics",
    q: "Is it really open source?",
    a: "Yes — Apache 2.0. The whole server, web UI, CLI, and storage backends are in the open. There is no closed-core, no enterprise SKU, no telemetry. Read the code, fork it, ship it.",
  },

  // Workflow
  {
    cat: "workflow",
    q: "Do my developers have to install anything new?",
    a: "No. They keep using dart pub get, dart pub add, and dart pub publish. The only difference is the hosted: URL in pubspec.yaml points at your CLUB server instead of <a href='https://pub.dev'>pub.dev</a>.",
  },
  {
    cat: "workflow",
    q: "How does publishing from CI work?",
    a: "Use the club CLI (or our GitHub Action) with a per-package upload token. Tokens are scoped to the package, not the user — rotate without touching any human accounts.",
  },
  {
    cat: "workflow",
    q: "Does it handle pub scoring and dartdoc?",
    a: "Yes. Every published version is scored with the same <a href='https://pub.dev/packages/pana'>pana</a> engine <a href='https://pub.dev'>pub.dev</a> uses, and the API reference is generated and hosted automatically alongside the README. No extra pipeline to wire up.",
  },

  // Control
  {
    cat: "control",
    q: "Can I unlist or remove a published version?",
    a: "Yes — that's a big part of why people self-host. You can unlist, retract, force-overwrite, or fully delete versions. All of it is audit-logged and gated behind the Admin role.",
  },
  {
    cat: "control",
    q: "How does access control work?",
    a: "Three roles — Admin, Editor, Viewer — applied at the publisher level. Admins do everything, Editors publish and curate, Viewers read and download. Tokens for CI are separate and scoped per-package.",
  },
  {
    cat: "control",
    q: "Can I move packages between publishers?",
    a: "Yes. Publishers map to teams, and ownership transfers are a first-class action — no database surgery, no support ticket. Old uploaders are revoked, new ones are issued.",
  },

  // Deploy
  {
    cat: "deploy",
    q: "What does it take to run CLUB?",
    a: "One container. Multi-arch (linux/amd64 + linux/arm64), with the server, web UI, and dartdoc generation bundled in. SQLite + filesystem works out of the box for small teams; swap to S3 or GCS with an env var when you scale.",
  },
  {
    cat: "deploy",
    q: "Which storage backends are supported?",
    a: "Filesystem (default — great for dev and small deployments), Amazon S3, and Google Cloud Storage / Firebase Storage. The blob store is an interface — bringing another backend is a few hundred lines.",
  },
  {
    cat: "deploy",
    q: "Is it production-ready?",
    a: "Yes. CLUB is built on shelf, drift/SQLite, and bcrypt + JWT — the same boring, audited primitives you'd reach for yourself. Stand up TLS at your ingress and you're done.",
  },

  // Trust
  {
    cat: "trust",
    q: "Does CLUB phone home?",
    a: "No telemetry. No analytics pixel. No third-party SDK. The only network calls the server makes are to your storage backend and to whatever you configure for SMTP. Audit the source if you want to verify.",
  },
  {
    cat: "trust",
    q: "Can I use my own privacy policy and terms?",
    a: "Yes — drop in your /privacy and /terms pages and they wire into the UI automatically. Pair that with your TLS cert and your DNS, and the whole thing reads like your company. Because it is.",
  },
];

// Three tenets used by the Manifesto approach
export const TENETS = [
  {
    n: "I.",
    title: "Your packages",
    lead: "Private by default — and private on your terms.",
    body: "CLUB doesn't phone home. There is no telemetry, no analytics pixel, no third-party SDK. Every package, every score, every download count lives inside your infrastructure. If you can audit the code, you can trust the product — and you can audit the code.",
  },
  {
    n: "II.",
    title: "Your server",
    lead: "One container. Your cloud, your hardware, your rules.",
    body: "CLUB ships as a single Docker image on linux/amd64 and linux/arm64. It includes the server, the web UI, dartdoc generation, and admin tooling. Point it at the storage you already use — filesystem, S3, or Firebase Storage — and deploy it where you deploy everything else.",
  },
  {
    n: "III.",
    title: "Your rules",
    lead: "The admin tools pub.dev doesn't give you.",
    body: "Unlist. Discontinue. Retract. Force-overwrite a broken version. Transfer a package to a new publisher. Revoke a CI token. Assign roles. Configure the privacy and terms pages so the whole UI reads like your company. Because it is.",
  },
];
