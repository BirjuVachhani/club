<script lang="ts">
  /**
   * Shared package-detail renderer used by both the latest-stable route
   * (`/packages/[pkg]`) and the versioned route
   * (`/packages/[pkg]/versions/[version]`).
   *
   * All data comes in via `{pkg, score, isLiked}` from `_loadPackage.ts`;
   * the component never touches route params directly.
   */
  import MarkdownRenderer from "$lib/components/MarkdownRenderer.svelte";
  import VerifiedBadge from "$lib/components/VerifiedBadge.svelte";
  import ScreenshotGallery from "$lib/components/ScreenshotGallery.svelte";
  import ScoresTab from "./_ScoresTab.svelte";
  import { api } from "$lib/api/client";
  import { confirmDialog } from "$lib/stores/confirm";

  interface Props {
    pkg: any;
    score: any;
    isLiked: boolean;
    canAdmin: boolean;
  }

  let { pkg, score, isLiked, canAdmin }: Props = $props();

  type Tab =
    | "readme"
    | "changelog"
    | "example"
    | "installing"
    | "versions"
    | "scores"
    | "admin"
    | "activity";
  const validTabs: Tab[] = [
    "readme",
    "changelog",
    "example",
    "installing",
    "versions",
    "scores",
    "admin",
    "activity",
  ];

  function tabFromHash(): Tab {
    if (typeof window === "undefined") return "readme";
    const h = window.location.hash.slice(1);
    return validTabs.includes(h as Tab) ? (h as Tab) : "readme";
  }

  let activeTab = $state<Tab>(tabFromHash());

  function setTab(tab: Tab) {
    activeTab = tab;
    history.replaceState(null, "", `#${tab}`);
  }

  // Mobile-only: metadata preview above the tabs + full-screen sheet
  // with the full sidebar content. Desktop renders the sidebar as usual.
  let mobileMetaOpen = $state(false);
  function openMobileMeta() { mobileMetaOpen = true; }
  function closeMobileMeta() { mobileMetaOpen = false; }

  $effect(() => {
    if (!mobileMetaOpen) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") closeMobileMeta();
    }
    window.addEventListener("keydown", onKey);
    // Lock body scroll so touch/wheel events scroll the sheet, not the
    // page behind it. Restore the previous value on close.
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  });

  // Sync tab when the user navigates back/forward.
  function onHashChange() {
    activeTab = tabFromHash();
  }
  $effect(() => {
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  });

  let liked = $state(false);
  let likeCount = $state(0);
  let likePending = $state(false);

  $effect(() => {
    liked = isLiked ?? false;
    likeCount = score?.likes ?? 0;
  });

  // Reset the active tab whenever we land on a different package or version.
  // Kept in its own effect so it does not re-fire when only the like state
  // changes.
  $effect(() => {
    // Touch both fields to establish reactive dependencies.
    void pkg?.name;
    void pkg?.version;
    setTab(tabFromHash());
  });

  async function toggleLike() {
    if (!pkg || likePending) return;
    likePending = true;
    try {
      if (liked) {
        await api.delete(`/api/account/likes/${pkg.name}`);
        liked = false;
        likeCount = Math.max(0, likeCount - 1);
      } else {
        await api.put(`/api/account/likes/${pkg.name}`);
        liked = true;
        likeCount += 1;
      }
    } catch {
      // Silently fail (user may not be logged in).
    } finally {
      likePending = false;
    }
  }

  let serverUrl = $derived(
    typeof window !== "undefined" ? window.location.origin : "",
  );

  let tags = $derived(score?.tags ?? []);
  let sdkTags = $derived(
    tags
      .filter((t: string) => t.startsWith("sdk:"))
      .map((t: string) => t.substring(4)),
  );
  let platformTags = $derived(
    tags
      .filter((t: string) => t.startsWith("platform:"))
      .map((t: string) => t.substring(9)),
  );

  // Split the version list into stable vs prerelease. Newest first in each
  // group (the loader already reverses the list).
  let stableVersions = $derived(
    (pkg?.versions ?? []).filter((v: any) => !v.isPrerelease),
  );
  let prereleaseVersions = $derived(
    (pkg?.versions ?? []).filter((v: any) => v.isPrerelease),
  );

  // ── Dartdoc status (sidebar + admin) ─────────────────────────
  let dartdocStatus = $state<any>(null);

  async function loadDartdocStatus() {
    if (!pkg) return;
    try {
      dartdocStatus = await api.get<any>(
        `/api/packages/${pkg.name}/dartdoc-status`,
      );
    } catch {
      dartdocStatus = null;
    }
  }

  // Load dartdoc status on mount / package change for the sidebar link.
  $effect(() => {
    void pkg?.name;
    loadDartdocStatus();
  });

  // ── Sidebar: publisher badge ─────────────────────────────────
  let sidebarPublisher = $state<{ id: string; verified: boolean } | null>(null);

  async function loadSidebarPublisher() {
    if (!pkg) return;
    sidebarPublisher = null;
    try {
      const info = await api
        .get<{ publisherId: string | null }>(
          `/api/packages/${pkg.name}/publisher`,
        )
        .catch(() => null);
      const id = info?.publisherId ?? null;
      if (!id) return;
      const detail = await api
        .get<{ verified?: boolean }>(`/api/publishers/${id}`)
        .catch(() => null);
      sidebarPublisher = { id, verified: detail?.verified === true };
    } catch {
      sidebarPublisher = null;
    }
  }

  $effect(() => {
    void pkg?.name;
    loadSidebarPublisher();
  });

  // ── Sidebar: weekly downloads (always rendered) ──────────────
  interface SidebarWeek {
    weekStart: string;
    weekLabel: string;
    total: number;
    byVersion: Record<string, number>;
  }
  interface SidebarDownloadHistory {
    packageName: string;
    total30Days: number;
    weeks: SidebarWeek[];
  }

  let sidebarDownloads = $state<SidebarDownloadHistory | null>(null);
  let sidebarDownloadsLoading = $state(true);

  async function loadSidebarDownloads() {
    if (!pkg) return;
    sidebarDownloadsLoading = true;
    sidebarDownloads = null;
    try {
      sidebarDownloads = await api.get<SidebarDownloadHistory>(
        `/api/packages/${pkg.name}/downloads`,
      );
    } catch {
      sidebarDownloads = null;
    } finally {
      sidebarDownloadsLoading = false;
    }
  }

  $effect(() => {
    void pkg?.name;
    loadSidebarDownloads();
  });

  // Compact chart geometry — rendered inline to keep the sidebar visually
  // tight compared to the elaborate Scores-tab chart.
  const SB_CHART_W = 240;
  const SB_CHART_H = 72;

  let sidebarChart = $derived.by(() => {
    const weeks = sidebarDownloads?.weeks ?? [];
    const hasData = weeks.length > 0 && weeks.some((w) => w.total > 0);
    if (!hasData) {
      return { areaPath: "", linePoints: "", hasData: false };
    }
    const max = Math.max(...weeks.map((w) => w.total), 1);
    const stepX =
      weeks.length > 1 ? SB_CHART_W / (weeks.length - 1) : SB_CHART_W / 2;
    const yOf = (v: number) =>
      SB_CHART_H - 3 - (v / max) * (SB_CHART_H - 6);
    const pts = weeks.map((w, i) => [i * stepX, yOf(w.total)] as const);
    const linePoints = pts
      .map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`)
      .join(" ");
    const areaPath =
      `M0,${SB_CHART_H} ` +
      pts.map(([x, y]) => `L${x.toFixed(1)},${y.toFixed(1)}`).join(" ") +
      ` L${SB_CHART_W},${SB_CHART_H} Z`;
    return { areaPath, linePoints, hasData: true };
  });

  let sidebarDateRange = $derived.by(() => {
    const weeks = sidebarDownloads?.weeks ?? [];
    if (weeks.length < 2) return "";
    const fmt = (s: string) => s.replaceAll("-", ".");
    return `${fmt(weeks[0].weekStart)} \u2013 ${fmt(
      weeks[weeks.length - 1].weekStart,
    )}`;
  });

  // ── Admin tab — scoring state ────────────────────────────────
  let scoringStatus = $state<any>(null);
  let reanalyzePending = $state(false);

  async function loadScoringStatus() {
    if (!pkg) return;
    try {
      const v = encodeURIComponent(pkg.version);
      scoringStatus = await api.get<any>(
        `/api/packages/${pkg.name}/versions/${v}/scoring-report`,
      );
    } catch {
      scoringStatus = null;
    }
  }

  async function triggerRescore() {
    if (!pkg || reanalyzePending) return;
    reanalyzePending = true;
    try {
      const v = encodeURIComponent(pkg.version);
      await api.post(`/api/admin/packages/${pkg.name}/versions/${v}/rescore`);
      adminMessage = "Analysis queued.";
      // Refresh scoring status.
      await loadScoringStatus();
    } catch {
      adminMessage = "Failed to trigger re-analysis.";
    } finally {
      reanalyzePending = false;
    }
  }

  let regenDocsPending = $state(false);

  async function triggerRegenerateDocs() {
    if (!pkg || regenDocsPending) return;
    regenDocsPending = true;
    try {
      await api.post(`/api/admin/packages/${pkg.name}/regenerate-docs`);
      adminMessage = "Documentation generation queued.";
      await loadDartdocStatus();
    } catch {
      adminMessage = "Failed to trigger doc generation.";
    } finally {
      regenDocsPending = false;
    }
  }

  // ── Admin tab state ─────────────────────────────────────────
  let adminLoaded = $state(false);
  let adminOptions = $state<any>({});
  let adminMessage = $state("");
  let adminLoading = $state(false);
  let deletePending = $state(false);

  // Confirmation dialog state
  type ConfirmAction = {
    title: string;
    message: string;
    onConfirm: () => void;
    /** When set, user must type this string to enable the confirm button. */
    typeToConfirm?: string;
  } | null;
  let pendingConfirm = $state<ConfirmAction>(null);
  let confirmInput = $state("");

  async function loadAdminData() {
    if (adminLoaded || !pkg) return;
    adminLoading = true;
    try {
      adminOptions = await api.get<any>(`/api/packages/${pkg.name}/options`);
      replacedByInput = adminOptions.replacedBy ?? "";
      adminLoaded = true;
    } catch {
      adminMessage = "Failed to load package options.";
    } finally {
      adminLoading = false;
    }
  }

  // ── Suggested replacement ────────────────────────────────────
  let replacedByInput = $state("");
  let replacedByBusy = $state(false);

  async function saveReplacedBy() {
    if (!pkg || replacedByBusy) return;
    replacedByBusy = true;
    try {
      adminOptions = await api.put<any>(`/api/packages/${pkg.name}/options`, {
        replacedBy: replacedByInput.trim(),
      });
      replacedByInput = adminOptions.replacedBy ?? "";
      adminMessage = replacedByInput
        ? `Suggested replacement set to "${replacedByInput}".`
        : "Suggested replacement cleared.";
    } catch {
      adminMessage = "Failed to update suggested replacement.";
    } finally {
      replacedByBusy = false;
    }
  }

  function confirmDiscontinued(e: Event) {
    e.preventDefault();
    if (!pkg) return;
    const willDiscontinue = !adminOptions.isDiscontinued;
    pendingConfirm = {
      title: willDiscontinue
        ? "Mark as discontinued?"
        : "Remove discontinued status?",
      message: willDiscontinue
        ? `This will mark "${pkg.name}" as discontinued. It will no longer appear in search results unless users use advanced search options.`
        : `This will remove the discontinued status from "${pkg.name}". It will appear in search results again.`,
      onConfirm: doToggleDiscontinued,
    };
  }

  async function doToggleDiscontinued() {
    if (!pkg) return;
    pendingConfirm = null;
    try {
      adminOptions = await api.put<any>(`/api/packages/${pkg.name}/options`, {
        isDiscontinued: !adminOptions.isDiscontinued,
      });
      adminMessage = adminOptions.isDiscontinued
        ? "Package marked as discontinued."
        : "Package no longer discontinued.";
    } catch {
      adminMessage = "Failed to update option.";
    }
  }

  function confirmUnlisted(e: Event) {
    e.preventDefault();
    if (!pkg) return;
    const willUnlist = !adminOptions.isUnlisted;
    pendingConfirm = {
      title: willUnlist ? "Mark as unlisted?" : "Relist package?",
      message: willUnlist
        ? `This will hide "${pkg.name}" from search results. Users can still access it directly or find it using advanced search.`
        : `This will make "${pkg.name}" visible in search results again.`,
      onConfirm: doToggleUnlisted,
    };
  }

  async function doToggleUnlisted() {
    if (!pkg) return;
    pendingConfirm = null;
    try {
      adminOptions = await api.put<any>(`/api/packages/${pkg.name}/options`, {
        isUnlisted: !adminOptions.isUnlisted,
      });
      adminMessage = adminOptions.isUnlisted
        ? "Package marked as unlisted."
        : "Package relisted.";
    } catch {
      adminMessage = "Failed to update option.";
    }
  }

  function confirmRetract(version: string, currentlyRetracted: boolean) {
    if (!pkg) return;
    const willRetract = !currentlyRetracted;
    pendingConfirm = {
      title: willRetract
        ? `Retract version ${version}?`
        : `Unretract version ${version}?`,
      message: willRetract
        ? `Retracting version ${version} will cause the pub client to warn users and prefer other versions when resolving dependencies. The version will still be available for download.`
        : `Unretracting version ${version} will restore it as a normal version. The pub client will no longer warn users about this version.`,
      onConfirm: () => doToggleRetracted(version, currentlyRetracted),
    };
  }

  async function doToggleRetracted(
    version: string,
    currentlyRetracted: boolean,
  ) {
    if (!pkg) return;
    pendingConfirm = null;
    try {
      await api.put<any>(
        `/api/packages/${pkg.name}/versions/${encodeURIComponent(version)}/options`,
        {
          isRetracted: !currentlyRetracted,
        },
      );
      pkg = {
        ...pkg,
        versions: pkg.versions.map((v: any) =>
          v.version === version ? { ...v, retracted: !currentlyRetracted } : v,
        ),
      };
      adminMessage = !currentlyRetracted
        ? `Version ${version} retracted.`
        : `Version ${version} unretracted.`;
    } catch {
      adminMessage = "Failed to update version option.";
    }
  }

  function confirmDelete() {
    if (!pkg) return;
    pendingConfirm = {
      title: `Delete ${pkg.name}?`,
      message: `This will permanently delete the package "${pkg.name}" and all its versions, archives, and metadata. This action cannot be undone.`,
      typeToConfirm: pkg.name,
      onConfirm: doDeletePackage,
    };
  }

  async function doDeletePackage() {
    if (!pkg || deletePending) return;
    pendingConfirm = null;
    deletePending = true;
    try {
      await api.delete(`/api/packages/${pkg.name}`);
      window.location.href = "/packages";
    } catch {
      adminMessage = "Failed to delete package.";
      deletePending = false;
    }
  }

  // ── Admin tab — uploaders ───────────────────────────────────
  type Uploader = { userId: string; email: string; displayName: string };
  let uploaders = $state<Uploader[]>([]);
  let newUploaderEmail = $state("");
  let uploaderBusy = $state(false);

  async function loadUploaders() {
    if (!pkg) return;
    try {
      const data = await api.get<{ uploaders: Uploader[] }>(
        `/api/packages/${pkg.name}/uploaders`,
      );
      uploaders = data.uploaders ?? [];
    } catch {
      // Non-fatal; admin tab simply shows an empty list.
    }
  }

  async function addUploader(e: Event) {
    e.preventDefault();
    if (!pkg || uploaderBusy) return;
    const email = newUploaderEmail.trim();
    if (!email) return;
    uploaderBusy = true;
    try {
      await api.put(
        `/api/packages/${pkg.name}/uploaders/${encodeURIComponent(email)}`,
        {},
      );
      adminMessage = `Added ${email} as an uploader.`;
      newUploaderEmail = "";
      await loadUploaders();
    } catch (e: any) {
      adminMessage = e?.body?.error?.message ?? "Failed to add uploader.";
    } finally {
      uploaderBusy = false;
    }
  }

  async function removeUploader(email: string) {
    if (!pkg) return;
    if (uploaders.length <= 1) {
      adminMessage = "Cannot remove the last uploader.";
      return;
    }
    const ok = await confirmDialog({
      title: "Remove uploader?",
      description: `${email} will no longer be able to publish new versions of this package.`,
      confirmLabel: "Remove",
      confirmVariant: "destructive"
    });
    if (!ok) return;
    try {
      await api.delete(
        `/api/packages/${pkg.name}/uploaders/${encodeURIComponent(email)}`,
      );
      adminMessage = `Removed ${email}.`;
      await loadUploaders();
    } catch (e: any) {
      adminMessage = e?.body?.error?.message ?? "Failed to remove uploader.";
    }
  }

  // ── Admin tab — publisher assignment ────────────────────────
  //
  // We only list publishers the user is ADMIN of — the server enforces
  // this on the destination side too, but filtering client-side means
  // the dropdown can't even suggest an invalid target. `verified` flows
  // through so the UI can show the badge next to each option.
  type PublisherLite = {
    publisherId: string;
    displayName: string;
    role: "admin" | "member";
    verified?: boolean;
  };
  let currentPublisherId = $state<string | null>(null);
  let currentPublisherVerified = $state<boolean>(false);
  let myPublishers = $state<PublisherLite[]>([]);
  let publisherChoice = $state<string>("");
  let publisherBusy = $state(false);

  async function loadPublisherState() {
    if (!pkg) return;
    try {
      const [pubInfo, mine] = await Promise.all([
        api.get<any>(`/api/packages/${pkg.name}/publisher`).catch(() => null),
        api
          .get<{ publishers: PublisherLite[] }>("/api/account/publishers")
          .catch(() => ({ publishers: [] })),
      ]);
      currentPublisherId = pubInfo?.publisherId ?? null;

      // If the package is currently owned by a publisher, resolve its
      // `verified` flag separately — the /publisher endpoint only
      // returns the ID. Cheap round-trip; doesn't block the main flow.
      currentPublisherVerified = false;
      if (currentPublisherId) {
        try {
          const current = await api.get<any>(
            `/api/publishers/${currentPublisherId}`,
          );
          currentPublisherVerified = current?.verified === true;
        } catch {
          // Non-fatal — worst case the badge doesn't show.
        }
      }

      myPublishers = (mine?.publishers ?? []).filter(
        (p: any) => p.role === "admin",
      );
      publisherChoice = currentPublisherId ?? "";
    } catch {
      // Non-fatal.
    }
  }

  // Post-transfer result dialog. Separate from pendingConfirm so the
  // confirmation closes before the success/failure message appears —
  // otherwise they'd briefly stack.
  type TransferResult = {
    title: string;
    message: string;
    tone: "success" | "error";
  } | null;
  let transferResult = $state<TransferResult>(null);

  function requestSetPublisher(newId: string | null) {
    if (!pkg || publisherBusy) return;
    const from = currentPublisherId ?? null;
    if (from === newId) return;

    const title = newId
      ? from
        ? `Transfer ${pkg.name} to ${newId}?`
        : `Assign ${pkg.name} to ${newId}?`
      : `Clear publisher for ${pkg.name}?`;
    const message = newId
      ? from
        ? `The package "${pkg.name}" will move from publisher "${from}" to "${newId}". Admins of "${newId}" will gain admin rights over the package. You can transfer it back later if needed.`
        : `The package "${pkg.name}" will be owned by publisher "${newId}". Admins of "${newId}" will gain admin rights over the package. You can clear the publisher later to revert to uploader ownership.`
      : `The package "${pkg.name}" will no longer be owned by publisher "${from}". It will revert to being owned by its uploaders.`;

    pendingConfirm = {
      title,
      message,
      onConfirm: () => doSetPublisher(newId),
    };
  }

  async function doSetPublisher(newId: string | null) {
    if (!pkg || publisherBusy) return;
    pendingConfirm = null;
    publisherBusy = true;
    try {
      await api.put(`/api/packages/${pkg.name}/publisher`, {
        publisherId: newId,
      });
      currentPublisherId = newId;
      const successMsg = newId
        ? `Transferred to publisher ${newId}.`
        : "Cleared publisher; package is now uploader-owned.";
      adminMessage = successMsg;
      transferResult = {
        title: newId ? "Transfer complete" : "Publisher cleared",
        message: successMsg,
        tone: "success",
      };
    } catch (e: any) {
      const errMsg = e?.body?.error?.message ?? "Failed to change publisher.";
      adminMessage = errMsg;
      transferResult = {
        title: "Transfer failed",
        message: errMsg,
        tone: "error",
      };
    } finally {
      publisherBusy = false;
    }
  }

  // ── Activity Log tab state ──────────────────────────────────
  let activityLoaded = $state(false);
  let activityEntries = $state<any[]>([]);
  let activityLoading = $state(false);

  async function loadActivityLog() {
    if (activityLoaded || !pkg) return;
    activityLoading = true;
    try {
      const data = await api.get<any>(`/api/packages/${pkg.name}/activity-log`);
      activityEntries = data.entries ?? [];
      activityLoaded = true;
    } catch {
      // silently fail
    } finally {
      activityLoading = false;
    }
  }

  // Lazy-load tab data when switching to admin or activity tabs.
  $effect(() => {
    if (activeTab === "admin") {
      loadAdminData();
      loadScoringStatus();
      loadDartdocStatus();
      loadUploaders();
      loadPublisherState();
    }
    if (activeTab === "activity") loadActivityLog();
  });

  function timeAgo(dateStr: string | null): string {
    if (!dateStr) return "";
    const diff = Date.now() - new Date(dateStr).getTime();
    const days = Math.floor(diff / 86400000);
    if (days === 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 30) return `${days} days ago`;
    if (days < 365) return `${Math.floor(days / 30)} months ago`;
    return `${Math.floor(days / 365)} years ago`;
  }

  function formatDate(dateStr: string): string {
    return new Date(dateStr).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function formatNumber(n: number): string {
    if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
    return n.toString();
  }

  function copyInstall() {
    if (!pkg) return;
    navigator.clipboard.writeText(`${pkg.name}: ^${pkg.version}`);
  }
</script>

<svelte:head>
  <title>{pkg ? `${pkg.name} | Dart package` : "Package | CLUB"}</title>
</svelte:head>

{#if pkg}
  <div class="pkg-page">
    {#if pkg.isLatest === false}
      <!--
        Only surface the banner when we're actually viewing a version other
        than the current latest stable. Without this, visiting
        /versions/<latest> would show a misleading warning.
      -->
      <div class="version-banner" class:prerelease={pkg.isViewingPrerelease}>
        <div>
          {#if pkg.isViewingPrerelease}
            Viewing <strong>prerelease</strong> version
            <code>{pkg.version}</code>.
          {:else}
            Viewing version <code>{pkg.version}</code> — not the latest stable.
          {/if}
          {#if pkg.latestStableVersion}
            <a href="/packages/{pkg.name}">
              Go to latest stable ({pkg.latestStableVersion})
            </a>
          {/if}
        </div>
      </div>
    {/if}

    <button
      class="like-btn"
      class:liked
      onclick={toggleLike}
      disabled={likePending}
      title={liked ? "Unlike" : "Like"}
    >
      <svg
        width="18"
        height="18"
        viewBox="0 0 24 24"
        fill={liked ? "currentColor" : "none"}
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path
          d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"
        />
      </svg>
    </button>

    <header class="pkg-header">
      <div class="pkg-title-row">
        <h1 class="pkg-name">{pkg.name}</h1>
        <span class="pkg-version">{pkg.version}</span>
        {#if pkg.isViewingPrerelease}
          <span class="badge-pre" title="Pre-release version">pre</span>
        {/if}
        <button class="copy-btn" onclick={copyInstall} title="Copy dependency">
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            ><rect x="9" y="9" width="13" height="13" rx="2" /><path
              d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"
            /></svg
          >
        </button>
      </div>
      <div class="pkg-meta">
        <span class="published">Published {timeAgo(pkg.publishedAt)}</span>
        {#if pkg.homepage}
          <span class="meta-sep">&bull;</span>
          <a
            href={pkg.homepage}
            target="_blank"
            rel="noopener"
            class="meta-link"
          >
            {pkg.homepageHost ?? pkg.homepage}
          </a>
        {/if}
        {#if pkg.latestPrereleaseVersion && pkg.latestStableVersion}
          <span class="meta-sep">&bull;</span>
          <span class="version-channels">
            Latest:
            <a href="/packages/{pkg.name}" class="meta-link"
              >{pkg.latestStableVersion}</a
            >
            <span class="meta-slash">/</span>
            Prerelease:
            <a
              href="/packages/{pkg.name}/versions/{encodeURIComponent(
                pkg.latestPrereleaseVersion,
              )}"
              class="meta-link">{pkg.latestPrereleaseVersion}</a
            >
          </span>
        {/if}
      </div>
      {#if sdkTags.length > 0 || platformTags.length > 0 || pkg.isDiscontinued || pkg.isUnlisted}
        <div class="pkg-compat">
          {#if pkg.isDiscontinued}
            <span class="badge-disc">DISCONTINUED</span>
          {/if}
          {#if sdkTags.length > 0}
            <div class="compat-row">
              <span class="compat-label">SDK</span>
              {#each sdkTags as sdk}
                <span class="compat-tag">{sdk.toUpperCase()}</span>
              {/each}
            </div>
          {/if}
          {#if platformTags.length > 0}
            <div class="compat-row">
              <span class="compat-label">PLATFORM</span>
              {#each platformTags as platform}
                <span class="compat-tag">{platform.toUpperCase()}</span>
              {/each}
            </div>
          {/if}
          {#if pkg.isUnlisted}
            <span class="badge-unlisted">UNLISTED</span>
          {/if}
        </div>
      {/if}
    </header>

    <div class="pkg-body">
      <div class="pkg-content">
        {#if pkg.isDiscontinued}
          <div class="discontinued-banner" role="alert">
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
              ><path
                d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"
              /><line x1="12" y1="9" x2="12" y2="13" /><line
                x1="12"
                y1="17"
                x2="12.01"
                y2="17"
              /></svg
            >
            <div class="discontinued-banner-text">
              <strong>This package is discontinued.</strong>
              <span>
                The author has marked it as no longer maintained.
                {#if pkg.replacedBy}
                  The author suggests <a href="/packages/{pkg.replacedBy}"
                    >{pkg.replacedBy}</a
                  > as a replacement.
                {/if}
              </span>
            </div>
          </div>
        {/if}

        <!-- Mobile-only: condensed metadata preview with "More..." affordance.
             Keeps the first screen focused on the README while still
             surfacing the description; the full sidebar lives in a bottom
             sheet. The desktop sidebar renders the same content inline. -->
        {#if pkg.description || pkg.homepage || pkg.repository || pkg.issueTracker || sidebarPublisher || pkg.topics?.length > 0 || pkg.dartSdk || pkg.flutterSdk || pkg.dependencies}
          <button class="mobile-meta-card" type="button" onclick={openMobileMeta}>
            <div class="mobile-meta-head">
              <h3>Metadata</h3>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/>
              </svg>
            </div>
            {#if pkg.description}
              <p class="mobile-meta-desc">{pkg.description}</p>
            {/if}
            <span class="mobile-meta-more">More...</span>
          </button>
        {/if}

        <nav class="tab-bar">
          <button
            class="tab"
            class:active={activeTab === "readme"}
            onclick={() => setTab("readme")}>Readme</button
          >
          <button
            class="tab"
            class:active={activeTab === "changelog"}
            onclick={() => setTab("changelog")}>Changelog</button
          >
          {#if pkg.example}
            <button
              class="tab"
              class:active={activeTab === "example"}
              onclick={() => setTab("example")}>Example</button
            >
          {/if}
          <button
            class="tab"
            class:active={activeTab === "installing"}
            onclick={() => setTab("installing")}>Installing</button
          >
          <button
            class="tab"
            class:active={activeTab === "versions"}
            onclick={() => setTab("versions")}>Versions</button
          >
          <button
            class="tab"
            class:active={activeTab === "scores"}
            onclick={() => setTab("scores")}>Scores</button
          >
          {#if canAdmin}
            <button
              class="tab tab-admin"
              class:active={activeTab === "admin"}
              onclick={() => setTab("admin")}>Admin</button
            >
            <button
              class="tab tab-admin"
              class:active={activeTab === "activity"}
              onclick={() => setTab("activity")}>Activity Log</button
            >
          {/if}
        </nav>
        <div class="tab-panel">
          {#if activeTab === "readme"}
            {#if pkg.readme}<MarkdownRenderer content={pkg.readme} />{:else}<p
                class="empty-tab"
              >
                No readme available.
              </p>{/if}
          {:else if activeTab === "changelog"}
            {#if pkg.changelog}<MarkdownRenderer
                content={pkg.changelog}
              />{:else}<p class="empty-tab">No changelog available.</p>{/if}
          {:else if activeTab === "example"}
            {#if pkg.example}
              <div class="example">
                {#if pkg.examplePath}
                  <p class="example-path">
                    From <code>{pkg.examplePath}</code>
                  </p>
                {/if}
                {#if pkg.examplePath && /\.(md|markdown|mdown)$/i.test(pkg.examplePath)}
                  <MarkdownRenderer content={pkg.example} />
                {:else}
                  <pre><code class="language-dart">{pkg.example}</code></pre>
                {/if}
              </div>
            {:else}
              <p class="empty-tab">No example available.</p>
            {/if}
          {:else if activeTab === "installing"}
            {@const installCmd = pkg.usesFlutter
              ? "flutter pub add"
              : "dart pub add"}
            <div class="installing">
              {#if pkg.executables && pkg.executables.length > 0}
                <h3>Use this package as an executable</h3>
                <p class="install-desc">Activate globally:</p>
                <pre><code class="language-bash"
                    >dart pub global activate --hosted-url {serverUrl} {pkg.name}</code
                  ></pre>
                <p class="install-desc">
                  The package provides {pkg.executables.length === 1
                    ? "this executable"
                    : "these executables"}:
                  <code>{pkg.executables.join(", ")}</code>.
                </p>
              {/if}

              <h3>Use this package as a library</h3>
              <p class="install-desc">Run this command:</p>
              <pre><code class="language-bash"
                  >{installCmd} {pkg.name} --hosted-url {serverUrl}</code
                ></pre>

              <p class="install-desc">Or, with the club CLI:</p>
              <pre><code class="language-bash"
                  >club add {pkg.name} --server {serverUrl}</code
                ></pre>

              <p class="install-desc">
                Or add it manually to your <code>pubspec.yaml</code>:
              </p>
              <pre><code class="language-yaml"
                  >dependencies:
  {pkg.name}:
    hosted: {serverUrl}
    version: ^{pkg.version}</code
                ></pre>

              <p class="install-desc">
                Then run <code
                  >{pkg.usesFlutter ? "flutter pub get" : "dart pub get"}</code
                >.
              </p>

              <h3>Import it</h3>
              <p class="install-desc">Now in your Dart code, you can use:</p>
              <pre><code class="language-dart"
                  >import 'package:{pkg.name}/{pkg.name}.dart';</code
                ></pre>
            </div>
          {:else if activeTab === "versions"}
            <!-- Stable versions -->
            {#if stableVersions.length > 0}
              <h3 class="versions-heading">Versions of {pkg.name}</h3>
              <div class="versions-list">
                {@render versionHeader()}
                {#each stableVersions as v}
                  {@render versionRow(v)}
                {/each}
              </div>
            {/if}

            <!-- Prerelease versions (only when some exist) -->
            {#if prereleaseVersions.length > 0}
              <h3 class="versions-heading prerelease">
                Prerelease versions of {pkg.name}
              </h3>
              <div class="versions-list">
                {@render versionHeader()}
                {#each prereleaseVersions as v}
                  {@render versionRow(v)}
                {/each}
              </div>
            {/if}

            {#if stableVersions.length === 0 && prereleaseVersions.length === 0}
              <p class="empty-tab">No versions available.</p>
            {/if}
          {:else if activeTab === "scores"}
            <ScoresTab packageName={pkg.name} version={pkg.version} />
          {:else if activeTab === "admin"}
            <div class="admin-tab">
              {#if adminMessage}
                <div class="admin-message">{adminMessage}</div>
              {/if}

              {#if adminLoading}
                <p class="empty-tab">Loading...</p>
              {:else}
                <section class="admin-section">
                  <h3>Package options</h3>

                  <div class="option-group">
                    <h4>Discontinued</h4>
                    <p class="option-desc">
                      A package can be marked as discontinued to inform users
                      that the package is no longer maintained. Discontinued
                      packages remain viewable by direct URL, but they don't
                      appear in search results or browse listings.
                    </p>
                    <label class="option-toggle">
                      <input
                        type="checkbox"
                        checked={adminOptions.isDiscontinued}
                        onchange={confirmDiscontinued}
                      />
                      Mark "discontinued"
                    </label>

                    {#if adminOptions.isDiscontinued}
                      <div class="replaced-by">
                        <label class="publisher-control-label">
                          <span>Suggested replacement</span>
                          <input
                            type="text"
                            class="replaced-by-input"
                            bind:value={replacedByInput}
                            placeholder="package_name"
                            disabled={replacedByBusy}
                          />
                        </label>
                        <button
                          class="uploader-add-btn"
                          onclick={saveReplacedBy}
                          disabled={replacedByBusy ||
                            replacedByInput.trim() ===
                              (adminOptions.replacedBy ?? "")}
                        >
                          {replacedByBusy
                            ? "Saving..."
                            : 'Update "Suggested Replacement"'}
                        </button>
                      </div>
                    {/if}
                  </div>

                  <div class="option-group">
                    <h4>Unlisted</h4>
                    <p class="option-desc">
                      A package that's marked as unlisted doesn't normally
                      appear in search results. Unlisted packages remain
                      publicly available to package users, and users can search
                      for them using advanced search options.
                    </p>
                    <label class="option-toggle">
                      <input
                        type="checkbox"
                        checked={adminOptions.isUnlisted}
                        onchange={confirmUnlisted}
                      />
                      Mark "unlisted"
                    </label>
                  </div>
                </section>

                <section class="admin-section">
                  <h3>Uploaders</h3>
                  <p class="option-desc">
                    Users listed here can publish new versions of this package.
                    An uploader can add or remove other uploaders.
                  </p>
                  <ul class="uploader-list">
                    {#each uploaders as u (u.userId)}
                      {@const initials = (u.displayName || u.email || "?")
                        .trim()
                        .slice(0, 1)
                        .toUpperCase()}
                      <li class="uploader-row">
                        <span class="uploader-avatar" aria-hidden="true"
                          >{initials}</span
                        >
                        <div class="uploader-identity">
                          <span class="uploader-name"
                            >{u.displayName || u.email}</span
                          >
                          {#if u.displayName && u.email && u.displayName !== u.email}
                            <span class="uploader-email">{u.email}</span>
                          {/if}
                        </div>
                        <button
                          class="uploader-remove"
                          onclick={() => removeUploader(u.email)}
                          disabled={uploaders.length <= 1}
                          title={uploaders.length <= 1
                            ? "Cannot remove the last uploader"
                            : "Remove uploader"}
                        >
                          Remove
                        </button>
                      </li>
                    {/each}
                  </ul>
                  <form class="uploader-add" onsubmit={addUploader}>
                    <input
                      type="email"
                      placeholder="email@example.com"
                      bind:value={newUploaderEmail}
                      disabled={uploaderBusy}
                      required
                    />
                    <button
                      type="submit"
                      class="uploader-add-btn"
                      disabled={uploaderBusy || !newUploaderEmail.trim()}
                    >
                      {uploaderBusy ? "Adding..." : "Add uploader"}
                    </button>
                  </form>
                </section>

                <section class="admin-section">
                  <h3>Publisher</h3>
                  <p class="option-desc">
                    A package can be owned by a publisher (an organization).
                    Transfer it to another publisher you administer, or clear
                    the publisher to revert to individual uploaders.
                  </p>

                  <div
                    class="publisher-card"
                    class:is-owned={currentPublisherId}
                  >
                    <div class="publisher-card-icon" aria-hidden="true">
                      {#if currentPublisherId}
                        <!-- badge-check icon -->
                        <svg
                          width="18"
                          height="18"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="2"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          ><path
                            d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"
                          /><path d="m9 12 2 2 4-4" /></svg
                        >
                      {:else}
                        <!-- user icon for uploader-owned -->
                        <svg
                          width="18"
                          height="18"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="2"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          ><path
                            d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"
                          /><circle cx="12" cy="7" r="4" /></svg
                        >
                      {/if}
                    </div>
                    <div class="publisher-card-text">
                      <span class="publisher-card-label">
                        {currentPublisherId
                          ? "Owned by publisher"
                          : "No publisher"}
                      </span>
                      <span class="publisher-card-value">
                        {#if currentPublisherId}
                          <a
                            href="/publishers/{currentPublisherId}"
                            class="publisher-link">{currentPublisherId}</a
                          >
                          {#if currentPublisherVerified}
                            <VerifiedBadge iconOnly />
                          {/if}
                        {:else}
                          Owned directly by uploaders
                        {/if}
                      </span>
                    </div>
                  </div>

                  {#if myPublishers.length > 0 || currentPublisherId}
                    <div class="publisher-controls">
                      <label class="publisher-control-label">
                        <span>Change ownership</span>
                        <select
                          bind:value={publisherChoice}
                          disabled={publisherBusy}
                        >
                          <option value=""
                            >(clear publisher — revert to uploaders)</option
                          >
                          {#each myPublishers as p (p.publisherId)}
                            <option value={p.publisherId}>
                              {p.displayName}{p.verified ? " ✓" : ""} ({p.publisherId})
                            </option>
                          {/each}
                        </select>
                      </label>
                      <button
                        class="uploader-add-btn"
                        onclick={() =>
                          requestSetPublisher(
                            publisherChoice ? publisherChoice : null,
                          )}
                        disabled={publisherBusy ||
                          publisherChoice === (currentPublisherId ?? "")}
                      >
                        {publisherBusy ? "Saving..." : "Apply"}
                      </button>
                    </div>
                  {:else}
                    <p class="empty-hint">
                      You aren't an admin of any publisher. Ask a server admin
                      to create one or add you as a publisher admin.
                    </p>
                  {/if}
                </section>

                <section class="admin-section">
                  <h3>Version retraction</h3>
                  <p class="option-desc">
                    Retracted versions are still available for download, but the
                    pub client will warn users and prefer non-retracted versions
                    when resolving dependencies.
                  </p>
                  <div class="retraction-list">
                    {#each pkg?.versions ?? [] as v}
                      <div class="retraction-row">
                        <span class="retraction-version">
                          {v.version}
                          {#if v.retracted}<span class="badge-ret"
                              >retracted</span
                            >{/if}
                        </span>
                        <button
                          class="retraction-btn"
                          class:retract={!v.retracted}
                          class:unretract={v.retracted}
                          onclick={() => confirmRetract(v.version, v.retracted)}
                        >
                          {v.retracted ? "Unretract" : "Retract"}
                        </button>
                      </div>
                    {/each}
                  </div>
                </section>

                <section class="admin-section">
                  <h3>Scoring</h3>
                  <p class="option-desc">
                    Pana analysis for the currently viewed version ({pkg.version}).
                  </p>
                  {#if scoringStatus}
                    <div class="scoring-admin-status">
                      {#if scoringStatus.status === "completed"}
                        <span class="scoring-badge completed">Completed</span>
                        <span class="scoring-detail"
                          >{scoringStatus.grantedPoints}/{scoringStatus.maxPoints}
                          points</span
                        >
                      {:else if scoringStatus.status === "pending"}
                        <span class="scoring-badge pending">Pending</span>
                      {:else if scoringStatus.status === "running"}
                        <span class="scoring-badge pending">Running</span>
                      {:else if scoringStatus.status === "failed"}
                        <span class="scoring-badge failed">Failed</span>
                      {:else if scoringStatus.status === "disabled"}
                        <span class="scoring-badge disabled">Disabled</span>
                      {:else}
                        <span class="scoring-badge disabled">Not analyzed</span>
                      {/if}
                    </div>
                    {#if scoringStatus.status === "failed" && scoringStatus.errorMessage}
                      <details class="scoring-error-details">
                        <summary>Error details</summary>
                        <pre
                          class="scoring-error-log">{scoringStatus.errorMessage}</pre>
                      </details>
                    {/if}
                  {:else}
                    <span class="scoring-badge disabled">Not analyzed</span>
                  {/if}
                  <button
                    class="rescore-btn"
                    onclick={triggerRescore}
                    disabled={reanalyzePending ||
                      scoringStatus?.status === "disabled" ||
                      scoringStatus?.status === "pending" ||
                      scoringStatus?.status === "running"}
                  >
                    {reanalyzePending ? "Queuing..." : "Re-analyze"}
                  </button>
                </section>

                <section class="admin-section">
                  <h3>Documentation</h3>
                  <p class="option-desc">
                    API reference generated via dartdoc for the latest version ({pkg.latestStableVersion ??
                      pkg.version}).
                  </p>
                  {#if dartdocStatus}
                    <div class="scoring-admin-status">
                      {#if dartdocStatus.status === "completed"}
                        <span class="scoring-badge completed">Generated</span>
                        <span class="scoring-detail"
                          >{dartdocStatus.version}</span
                        >
                      {:else if dartdocStatus.status === "pending" || dartdocStatus.status === "running"}
                        <span class="scoring-badge pending">Generating</span>
                      {:else if dartdocStatus.status === "failed"}
                        <span class="scoring-badge failed">Failed</span>
                      {:else}
                        <span class="scoring-badge disabled">Not generated</span
                        >
                      {/if}
                    </div>
                  {:else}
                    <span class="scoring-badge disabled">Not generated</span>
                  {/if}
                  <button
                    class="rescore-btn"
                    onclick={triggerRegenerateDocs}
                    disabled={regenDocsPending}
                  >
                    {regenDocsPending ? "Queuing..." : "Re-generate docs"}
                  </button>
                </section>

                <section class="admin-section danger-zone">
                  <h3>Delete package</h3>
                  <p class="option-desc">
                    Permanently delete this package and all its versions. This
                    removes all published archives, version history, and
                    metadata. This action cannot be undone.
                  </p>
                  <button
                    class="danger-btn"
                    onclick={confirmDelete}
                    disabled={deletePending}
                  >
                    {deletePending ? "Deleting..." : "Delete this package"}
                  </button>
                </section>
              {/if}
            </div>
          {:else if activeTab === "activity"}
            <div class="activity-tab">
              {#if activityLoading}
                <p class="empty-tab">Loading...</p>
              {:else if activityEntries.length === 0}
                <p class="empty-tab">No activity recorded for this package.</p>
              {:else}
                <div class="activity-list">
                  {#each activityEntries as entry}
                    <div class="activity-row">
                      <span class="activity-time"
                        >{timeAgo(entry.createdAt)}</span
                      >
                      <div class="activity-detail">
                        <p class="activity-summary">{entry.summary}</p>
                        {#if entry.agent}
                          <p class="activity-agent">
                            by {entry.agent.displayName} ({entry.agent.email})
                          </p>
                        {/if}
                        <p class="activity-date">
                          {formatDate(entry.createdAt)}
                        </p>
                      </div>
                    </div>
                  {/each}
                </div>
              {/if}
            </div>
          {/if}
        </div>
      </div>

      <aside class="pkg-sidebar">
        {@render sidebarContent()}
      </aside>
    </div>

    {#snippet sidebarContent()}
      {#if score}
        <div class="scores">
          <div class="score-item">
            <span class="score-val">{formatNumber(likeCount)}</span><span
              class="score-lbl">likes</span
            >
          </div>
          <div class="score-item">
            <span class="score-val">{score.points || "—"}</span><span
              class="score-lbl">points</span
            >
          </div>
          <div class="score-item">
            <span class="score-val">{formatNumber(score.downloads ?? 0)}</span
            ><span class="score-lbl">downloads</span>
          </div>
        </div>
      {/if}

      {#if pkg.screenshots && pkg.screenshots.length > 0}
        <div class="sb-section sb-screenshots">
          <h4>Screenshots</h4>
          <ScreenshotGallery screenshots={pkg.screenshots} />
        </div>
      {/if}

      {#if pkg.description || pkg.homepage || pkg.repository || pkg.issueTracker}
        <div class="sb-section">
          <h4>Metadata</h4>
          {#if pkg.description}
            <p class="sb-desc">{pkg.description}</p>
          {/if}
          {#if pkg.homepage || pkg.repository || pkg.issueTracker}
            <ul class="sb-links">
              {#if pkg.homepage}
                <li>
                  <a href={pkg.homepage} target="_blank" rel="noopener"
                    >Homepage</a
                  >
                </li>
              {/if}
              {#if pkg.repository && pkg.repository !== pkg.homepage}
                <li>
                  <a href={pkg.repository} target="_blank" rel="noopener"
                    >Repository</a
                  >
                </li>
              {/if}
              {#if pkg.issueTracker}
                <li>
                  <a href={pkg.issueTracker} target="_blank" rel="noopener"
                    >View/report issues</a
                  >
                </li>
              {/if}
            </ul>
          {/if}
        </div>
      {/if}

      <div class="sb-section">
        <h4>Weekly Downloads</h4>
        {#if sidebarDownloadsLoading}
          <div class="sb-chart-skeleton" aria-hidden="true"></div>
        {:else if sidebarChart.hasData}
          <svg
            viewBox="0 0 {SB_CHART_W} {SB_CHART_H}"
            class="sb-chart"
            preserveAspectRatio="none"
            role="img"
            aria-label="Weekly download trend"
          >
            <path d={sidebarChart.areaPath} class="sb-chart-area" />
            <polyline
              points={sidebarChart.linePoints}
              class="sb-chart-line"
              fill="none"
            />
          </svg>
          {#if sidebarDateRange}
            <p class="sb-chart-range">{sidebarDateRange}</p>
          {/if}
        {:else}
          <div
            class="sb-chart-empty"
            style="height: {SB_CHART_H}px"
            aria-label="No download data yet"
          >
            <span>No download data yet</span>
          </div>
        {/if}
      </div>

      {#if pkg.dartSdk || pkg.flutterSdk}
        <div class="sb-section">
          <h4>Environment</h4>
          <ul class="sb-env">
            {#if pkg.dartSdk}<li>
                <span class="env-k">sdk</span><span class="env-v"
                  >{pkg.dartSdk}</span
                >
              </li>{/if}
            {#if pkg.flutterSdk}<li>
                <span class="env-k">flutter</span><span class="env-v"
                  >{pkg.flutterSdk}</span
                >
              </li>{/if}
          </ul>
        </div>
      {/if}

      {#if pkg.topics && pkg.topics.length > 0}
        <div class="sb-section">
          <h4>Topics</h4>
          <div class="sb-topics">
            {#each pkg.topics as topic}
              <span class="topic-tag">#{topic}</span>
            {/each}
          </div>
        </div>
      {/if}

      {#if dartdocStatus?.status === "completed" || pkg.documentation}
        <div class="sb-section">
          <h4>Documentation</h4>
          <ul class="sb-links">
            {#if dartdocStatus?.status === "completed"}
              <li>
                <a
                  href="/documentation/{pkg.name}/latest/"
                  target="_blank"
                  rel="noopener">API reference</a
                >
              </li>
            {/if}
            {#if pkg.documentation}
              <li>
                <a href={pkg.documentation} target="_blank" rel="noopener"
                  >Documentation</a
                >
              </li>
            {/if}
          </ul>
        </div>
      {/if}

      {#if sidebarPublisher}
        <div class="sb-section">
          <h4>Publisher</h4>
          <a
            class="sb-publisher"
            href="/publishers/{sidebarPublisher.id}"
          >
            {#if sidebarPublisher.verified}
              <VerifiedBadge
                iconOnly
                title="Verified publisher"
                class="sb-verified"
              />
            {/if}
            <span class="sb-publisher-id">{sidebarPublisher.id}</span>
          </a>
        </div>
      {/if}

      {#if pkg.dependencies && Object.keys(pkg.dependencies).length > 0}
        <div class="sb-section">
          <h4>Dependencies</h4>
          <ul class="sb-deps">
            {#each Object.entries(pkg.dependencies) as [name, constraint]}
              <li>
                <a href="/packages/{name}">{name}</a><span class="dep-v"
                  >{constraint}</span
                >
              </li>
            {/each}
          </ul>
        </div>
      {/if}
    {/snippet}

    {#if mobileMetaOpen}
      <div class="meta-sheet" role="dialog" aria-modal="true" aria-label="Package metadata">
        <div class="meta-sheet-head">
          <h2>Metadata</h2>
          <button class="meta-sheet-close" onclick={closeMobileMeta} aria-label="Close">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
        </div>
        <div class="meta-sheet-body">
          {@render sidebarContent()}
        </div>
      </div>
    {/if}

    {#if pendingConfirm}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="confirm-overlay"
        onkeydown={(e) => {
          if (e.key === "Escape") {
            pendingConfirm = null;
            confirmInput = "";
          }
        }}
      >
        <div class="confirm-dialog">
          <h3>{pendingConfirm.title}</h3>
          <p>{pendingConfirm.message}</p>
          {#if pendingConfirm.typeToConfirm}
            <label class="confirm-typed-label">
              Type <code>"{pendingConfirm.typeToConfirm}"</code> to confirm deletion.
              <input
                class="confirm-input"
                type="text"
                bind:value={confirmInput}
                autocomplete="off"
                spellcheck="false"
              />
            </label>
          {/if}
          <div class="confirm-actions">
            <button
              class="confirm-cancel"
              onclick={() => {
                pendingConfirm = null;
                confirmInput = "";
              }}>Cancel</button
            >
            <button
              class="confirm-proceed"
              onclick={pendingConfirm.onConfirm}
              disabled={!!pendingConfirm.typeToConfirm &&
                confirmInput !== pendingConfirm.typeToConfirm}>Confirm</button
            >
          </div>
        </div>
      </div>
    {/if}

    {#if transferResult}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="confirm-overlay"
        onkeydown={(e) => {
          if (e.key === "Escape") transferResult = null;
        }}
      >
        <div class="confirm-dialog">
          <h3 class:result-error={transferResult.tone === "error"}>
            {transferResult.title}
          </h3>
          <p>{transferResult.message}</p>
          <div class="confirm-actions">
            <button
              class="confirm-proceed"
              onclick={() => (transferResult = null)}>OK</button
            >
          </div>
        </div>
      </div>
    {/if}
  </div>
{:else}
  <div class="not-found">
    <h2>Package not found</h2>
    <p>The requested package could not be loaded.</p>
    <a href="/packages">Browse packages</a>
  </div>
{/if}

{#snippet versionHeader()}
  <div class="version-header">
    <span>Version</span>
    <span>Min Dart SDK</span>
    <span>Uploaded</span>
    <span aria-hidden="true"></span>
  </div>
{/snippet}

{#snippet versionRow(v: {
  version: string;
  published: string;
  retracted: boolean;
  isPrerelease: boolean;
  minDartSdk: string | null;
})}
  <div class="version-row" class:retracted={v.retracted}>
    <a
      class="version-main"
      href="/packages/{pkg.name}/versions/{encodeURIComponent(v.version)}"
    >
      <span class="version-num">{v.version}</span>
      {#if v.retracted}<span class="badge-ret">retracted</span>{/if}
      {#if v.isPrerelease}<span class="badge-pre" title="Pre-release">pre</span
        >{/if}
    </a>
    <span class="version-sdk">{v.minDartSdk ?? "—"}</span>
    <span class="version-date">{timeAgo(v.published)}</span>
    <a
      class="version-download"
      href="/api/archives/{pkg.name}-{encodeURIComponent(v.version)}.tar.gz"
      title="Download {pkg.name}-{v.version}.tar.gz"
      download
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
        <polyline points="7 10 12 15 17 10" />
        <line x1="12" y1="15" x2="12" y2="3" />
      </svg>
    </a>
  </div>
{/snippet}

<style>
  .pkg-page {
    width: 100%;
    max-width: 100%;
    position: relative;
  }

  /* Banner shown when we're viewing a non-latest version. */
  .version-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 16px;
    margin-bottom: 16px;
    border: 1px solid var(--border);
    border-left: 3px solid var(--pub-muted-text-color);
    background: var(--muted);
    border-radius: 8px;
    font-size: 13px;
    color: var(--pub-default-text-color);
  }
  .version-banner.prerelease {
    border-left-color: var(--pub-link-text-color);
  }
  .version-banner code {
    background: var(--pub-code-background);
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 12px;
  }
  .version-banner a {
    color: var(--pub-link-text-color);
    text-decoration: none;
    font-weight: 500;
  }
  .version-banner a:hover {
    text-decoration: underline;
  }

  .pkg-header {
    padding-bottom: 20px;
  }
  .pkg-title-row {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 6px 10px;
    margin-bottom: 6px;
  }
  .pkg-name {
    margin: 0;
    font-size: 22px;
    font-weight: 700;
    word-break: break-word;
  }
  @media (min-width: 640px) {
    .pkg-name { font-size: 26px; }
  }
  .pkg-version {
    font-size: 16px;
    color: var(--pub-muted-text-color);
  }
  @media (min-width: 640px) {
    .pkg-version { font-size: 18px; }
  }
  .copy-btn {
    background: none;
    border: none;
    color: var(--pub-muted-text-color);
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
    display: flex;
  }
  .copy-btn:hover {
    color: var(--pub-link-text-color);
    background: var(--pub-tag-background);
  }
  .pkg-meta {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .badge-disc {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 3px 10px;
    border-radius: 3px;
    background: var(--pub-error-color);
    color: #fff;
  }
  .badge-unlisted {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 3px 10px;
    border-radius: 3px;
    background: var(--pub-tag-background);
    color: var(--pub-tag-text-color);
    border: 1px solid var(--border);
  }
  .badge-ret {
    font-size: 10px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--pub-error-color);
    color: #fff;
  }
  .badge-pre {
    font-size: 10px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--pub-tag-background);
    color: var(--pub-tag-text-color);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .meta-sep {
    color: var(--pub-muted-text-color);
  }
  .meta-link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--pub-link-text-color);
    text-decoration: none;
    font-size: 13px;
  }
  .meta-link:hover {
    text-decoration: underline;
  }
  .version-channels {
    font-size: 13px;
    color: var(--pub-muted-text-color);
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .meta-slash {
    color: var(--pub-muted-text-color);
  }

  .pkg-compat {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 12px;
  }
  .compat-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    max-width: 100%;
    border: 1px solid
      color-mix(in srgb, var(--pub-link-text-color) 30%, transparent);
    border-radius: 4px;
    overflow: hidden;
  }
  .compat-label {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 7px 10px;
    background: color-mix(in srgb, var(--pub-link-text-color) 20%, transparent);
    color: var(--pub-link-text-color);
  }
  .compat-tag {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.03em;
    padding: 7px 10px;
    background: var(--pub-tag-background);
    color: var(--pub-tag-text-color);
    border-right: 1px solid
      color-mix(in srgb, var(--pub-tag-text-color) 15%, transparent);
  }
  .compat-tag:last-child {
    border-right: none;
  }

  .pkg-body {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 280px;
    gap: 32px;
    width: 100%;
  }
  @media (max-width: 768px) {
    .pkg-body {
      grid-template-columns: 1fr;
    }
    /* On mobile we surface metadata via the preview card above the tabs
       and a bottom sheet, so the inline aside disappears. */
    .pkg-sidebar {
      display: none;
    }
  }

  /* ── Mobile metadata preview card ───────────────────── */
  .mobile-meta-card {
    display: none;
  }
  @media (max-width: 768px) {
    .mobile-meta-card {
      display: block;
      width: 100%;
      text-align: left;
      padding: 14px 16px 16px;
      margin: 0 0 16px;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: var(--card);
      color: inherit;
      font: inherit;
      cursor: pointer;
      transition: border-color 0.15s, background 0.15s;
    }
    .mobile-meta-card:hover {
      border-color: color-mix(in srgb, var(--foreground) 20%, var(--border));
    }
    .mobile-meta-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      margin-bottom: 8px;
    }
    .mobile-meta-head h3 {
      margin: 0;
      font-size: 15px;
      font-weight: 600;
      color: var(--foreground);
    }
    .mobile-meta-head svg {
      color: var(--muted-foreground);
      flex-shrink: 0;
    }
    .mobile-meta-desc {
      margin: 0 0 10px;
      font-size: 14px;
      line-height: 1.55;
      color: var(--pub-default-text-color);
      display: -webkit-box;
      -webkit-line-clamp: 3;
      line-clamp: 3;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }
    .mobile-meta-more {
      display: block;
      text-align: right;
      font-size: 13px;
      font-weight: 600;
      color: var(--pub-link-text-color);
    }
  }

  /* ── Metadata full-screen sheet ─────────────────────── */
  .meta-sheet {
    position: fixed;
    inset: 0;
    /* Sits above the site header (z-100 in +layout.svelte) so the sheet
       fully occludes it while open. */
    z-index: 200;
    display: flex;
    flex-direction: column;
    background: var(--background);
    animation: meta-slide-up 0.22s ease-out;
  }
  .meta-sheet-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--card);
    flex-shrink: 0;
  }
  .meta-sheet-head h2 {
    margin: 0;
    font-size: 17px;
    font-weight: 600;
    color: var(--foreground);
  }
  .meta-sheet-close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border: none;
    border-radius: 8px;
    background: transparent;
    color: var(--muted-foreground);
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .meta-sheet-close:hover {
    background: var(--accent);
    color: var(--foreground);
  }
  .meta-sheet-body {
    padding: 4px 16px 24px;
    overflow-x: hidden;
    overflow-y: auto;
    overscroll-behavior: contain;
    -webkit-overflow-scrolling: touch;
    flex: 1 1 auto;
    min-height: 0;
  }
  /* Long package names / URLs inside the sheet must wrap, not push the
     sheet wider than the viewport. */
  .meta-sheet-body a,
  .meta-sheet-body .dep-v,
  .meta-sheet-body .env-v {
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  /* Re-parent the sidebar's score block so its absolutely-positioned
     like button doesn't try to render against the old desktop offset. */
  .meta-sheet-body .scores {
    margin-bottom: 4px;
  }
  @media (min-width: 769px) {
    .meta-sheet {
      display: none;
    }
  }

  @keyframes meta-slide-up {
    from { transform: translateY(100%); }
    to { transform: translateY(0); }
  }

  .pkg-content {
    min-width: 0;
    width: 100%;
  }

  .tab-bar {
    display: flex;
    gap: 4px;
    background: var(--muted);
    border: 1px solid var(--border);
    padding: 4px;
    border-radius: 10px;
    margin-bottom: 20px;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    scrollbar-width: none;
  }
  .tab-bar::-webkit-scrollbar { height: 0; }
  .tab {
    padding: 8px 14px;
    background: none;
    border: none;
    border-radius: 7px;
    color: var(--pub-muted-text-color);
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
    flex-shrink: 0;
    transition:
      background 0.15s,
      color 0.15s;
  }
  .tab:hover {
    color: var(--pub-default-text-color);
    background: color-mix(in srgb, var(--muted) 0%, var(--background) 50%);
  }
  .tab.active {
    background: var(--foreground);
    color: var(--background);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
  }
  .tab.tab-admin {
    color: var(--pub-error-color);
  }
  .tab.tab-admin:hover {
    color: var(--pub-error-color);
    background: color-mix(in srgb, var(--pub-error-color) 10%, transparent);
  }
  .tab.tab-admin.active {
    background: var(--pub-error-color);
    color: #fff;
  }
  .tab-panel {
    min-height: 200px;
    width: 100%;
  }
  .empty-tab {
    padding: 40px 0;
    text-align: center;
    color: var(--pub-muted-text-color);
    font-style: italic;
  }

  .installing {
    color: var(--pub-default-text-color);
  }
  .installing h3 {
    margin: 2.25rem 0 0.25rem;
    font-size: var(--text-xl);
    font-weight: 600;
    letter-spacing: var(--tracking-snug);
    line-height: var(--leading-tight);
    color: var(--pub-heading-text-color);
  }
  .installing h3:first-child {
    margin-top: 0.25rem;
  }
  .install-desc {
    margin: 0.75rem 0 0.5rem;
    max-width: 68ch;
    font-size: var(--text-body);
    line-height: var(--leading-body);
    color: var(--pub-default-text-color);
  }
  .install-desc code {
    font-size: 0.88em;
  }
  .installing pre {
    margin: 0.5rem 0 1.25rem;
  }
  .installing pre:last-child {
    margin-bottom: 0;
  }

  .example-path {
    margin: 0 0 14px;
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .example-path code {
    font-size: 12px;
    background: var(--pub-code-background);
    padding: 2px 6px;
    border-radius: 4px;
  }

  .versions-heading {
    font-size: 14px;
    font-weight: 600;
    margin: 0 0 8px;
    color: var(--pub-default-text-color);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .versions-heading:not(:first-child) {
    margin-top: 24px;
  }
  .versions-heading.prerelease {
    color: var(--pub-link-text-color);
  }

  .version-header,
  .version-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 140px 160px 40px;
    align-items: center;
    column-gap: 12px;
    font-size: 14px;
  }
  .version-header {
    padding: 10px 8px;
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--pub-muted-text-color);
    border-bottom: 2px solid var(--pub-divider-color);
  }
  .version-row {
    border-bottom: 1px solid var(--pub-divider-color);
    transition: background 0.12s;
  }
  .version-row:hover {
    background: var(--muted);
  }
  .version-row.retracted {
    opacity: 0.5;
  }
  .version-main {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 8px;
    min-width: 0;
    text-decoration: none;
    color: inherit;
  }
  .version-main:hover .version-num {
    text-decoration: underline;
  }
  .version-num {
    font-weight: 600;
    font-family: var(--pub-code-font-family);
    color: var(--pub-link-text-color);
  }
  .version-sdk {
    font-family: var(--pub-code-font-family);
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .version-date {
    color: var(--pub-muted-text-color);
    font-size: 13px;
  }
  @media (max-width: 640px) {
    .version-header,
    .version-row {
      grid-template-columns: minmax(0, 1fr) 90px 110px 32px;
      column-gap: 8px;
    }
  }
  .version-download {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    border: none;
    border-radius: 4px;
    color: var(--pub-muted-text-color);
    text-decoration: none;
    transition:
      color 0.12s,
      background 0.12s;
  }
  .version-download:hover {
    color: var(--pub-link-text-color);
    background: var(--pub-tag-background);
  }
  .version-download svg {
    flex-shrink: 0;
  }

  .pkg-sidebar {
    font-size: 13px;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px;
    align-self: start;
  }
  @media (min-width: 768px) {
    .pkg-sidebar { padding: 20px; }
  }
  .scores {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    padding-bottom: 16px;
    border-bottom: 1px solid var(--pub-divider-color);
    position: relative;
  }
  .score-item {
    text-align: center;
    min-width: 0;
    padding: 0 6px;
    border-right: 1px solid var(--pub-divider-color);
  }
  .score-item:last-child {
    border-right: none;
  }
  .score-val {
    display: block;
    font-size: 22px;
    font-weight: 400;
    color: var(--pub-link-text-color);
    line-height: 1.1;
    letter-spacing: -0.01em;
  }
  .score-lbl {
    display: block;
    margin-top: 4px;
    font-size: 10px;
    color: var(--pub-muted-text-color);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    white-space: nowrap;
  }
  .like-btn {
    position: absolute;
    top: 6px;
    right: calc(280px + 32px);
    background: none;
    border: none;
    color: var(--pub-muted-text-color);
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
    display: flex;
    transition: color 0.15s;
    z-index: 1;
  }
  @media (max-width: 768px) {
    .like-btn {
      right: 0;
    }
  }
  .like-btn:hover {
    color: var(--pub-error-color);
  }
  .like-btn.liked {
    color: var(--pub-error-color);
  }
  .like-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .sb-section {
    padding: 14px 0;
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .sb-section:last-child {
    border-bottom: none;
    padding-bottom: 0;
  }
  .sb-section h4 {
    margin: 0 0 8px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--foreground);
    font-weight: 600;
  }
  .sb-desc {
    margin: 0 0 12px;
    line-height: 1.5;
  }
  .sb-desc:last-child {
    margin-bottom: 0;
  }
  .sb-links {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .sb-env {
    list-style: none;
    padding: 0;
    margin: 0;
  }
  .sb-env li {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 0.75rem;
    padding: 2px 0;
    min-width: 0;
  }
  .env-k {
    flex: 1 1 auto;
    min-width: 0;
    overflow-wrap: anywhere;
    color: var(--pub-muted-text-color);
  }
  .env-v {
    flex-shrink: 0;
    font-family: var(--pub-code-font-family);
    font-size: 12px;
    white-space: nowrap;
  }
  .sb-deps {
    list-style: none;
    padding: 0;
    margin: 0;
  }
  .sb-deps li {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 0.75rem;
    padding: 2px 0;
    min-width: 0;
  }
  .sb-deps li > a {
    flex: 1 1 auto;
    min-width: 0;
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  .dep-v {
    flex-shrink: 0;
    font-family: var(--pub-code-font-family);
    font-size: 11px;
    color: var(--pub-muted-text-color);
    white-space: nowrap;
  }
  .sb-publisher {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--pub-link-text-color);
    text-decoration: none;
    font-size: 14px;
    line-height: 1.2;
  }
  .sb-publisher:hover .sb-publisher-id {
    text-decoration: underline;
  }
  .sb-publisher :global(.sb-verified) {
    font-size: 15px;
    color: var(--pub-link-text-color);
  }
  .sb-publisher-id {
    min-width: 0;
    overflow-wrap: anywhere;
  }

  .sb-chart {
    display: block;
    width: 100%;
    height: 72px;
    margin-top: 2px;
  }
  .sb-chart-area {
    fill: var(--pub-link-text-color);
    opacity: 0.14;
  }
  .sb-chart-line {
    stroke: var(--pub-link-text-color);
    stroke-width: 1.5;
    stroke-linejoin: round;
    stroke-linecap: round;
    vector-effect: non-scaling-stroke;
  }
  .sb-chart-range {
    margin: 6px 0 0;
    font-family: var(--pub-code-font-family);
    font-size: 11px;
    color: var(--pub-link-text-color);
    text-align: center;
    letter-spacing: 0.02em;
  }
  .sb-chart-skeleton {
    height: 72px;
    border-radius: 4px;
    background: linear-gradient(
      90deg,
      color-mix(in srgb, var(--pub-link-text-color) 6%, transparent),
      color-mix(in srgb, var(--pub-link-text-color) 12%, transparent),
      color-mix(in srgb, var(--pub-link-text-color) 6%, transparent)
    );
    background-size: 200% 100%;
    animation: sb-shimmer 1.2s ease-in-out infinite;
  }
  @keyframes sb-shimmer {
    0% {
      background-position: 100% 0;
    }
    100% {
      background-position: -100% 0;
    }
  }
  .sb-chart-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    background: color-mix(in srgb, var(--pub-link-text-color) 6%, transparent);
    color: var(--pub-muted-text-color);
    font-size: 12px;
    font-style: italic;
  }

  .sb-topics {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .topic-tag {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 4px;
    font-size: 12px;
    font-weight: 500;
    color: var(--pub-link-text-color);
    background: color-mix(in srgb, var(--pub-link-text-color) 10%, transparent);
    text-decoration: none;
  }

  .not-found {
    text-align: center;
    padding: 60px 0;
    color: var(--pub-muted-text-color);
  }
  .not-found h2 {
    color: var(--pub-heading-text-color);
  }

  /* ── Admin tab ─────────────────────────────────────────── */
  .admin-tab {
    font-size: 14px;
  }
  .admin-message {
    padding: 10px 14px;
    background: var(--pub-tag-background);
    border: 1px solid var(--border);
    border-radius: 6px;
    margin-bottom: 16px;
    font-size: 13px;
    color: var(--pub-default-text-color);
  }
  .admin-section {
    padding: 20px 0;
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .admin-section:last-child {
    border-bottom: none;
  }
  .admin-section h3 {
    font-size: 16px;
    font-weight: 600;
    margin: 0 0 12px;
    color: var(--pub-heading-text-color);
  }
  .option-group {
    margin-bottom: 20px;
  }
  .option-group:last-child {
    margin-bottom: 0;
  }
  .option-group h4 {
    font-size: 14px;
    font-weight: 600;
    margin: 0 0 6px;
    color: var(--pub-heading-text-color);
  }
  .option-desc {
    font-size: 13px;
    color: var(--pub-muted-text-color);
    line-height: 1.5;
    margin: 0 0 10px;
  }
  .option-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    font-size: 13px;
    color: var(--pub-default-text-color);
  }
  .retraction-list {
    display: flex;
    flex-direction: column;
    gap: 0;
  }
  .retraction-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .retraction-row:last-child {
    border-bottom: none;
  }
  .retraction-version {
    display: flex;
    align-items: center;
    gap: 8px;
    font-family: var(--pub-code-font-family);
    font-size: 13px;
    font-weight: 600;
    color: var(--pub-default-text-color);
  }
  .retraction-btn {
    padding: 4px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: transparent;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.12s;
    font-family: inherit;
  }
  .retraction-btn.retract {
    color: var(--pub-error-color);
    border-color: var(--pub-error-color);
  }
  .retraction-btn.retract:hover {
    background: var(--pub-error-color);
    color: #fff;
  }
  .retraction-btn.unretract {
    color: var(--primary);
    border-color: var(--primary);
  }
  .retraction-btn.unretract:hover {
    background: var(--primary);
    color: var(--primary-foreground);
  }

  /* ── Uploaders ─────────────────────────────────────────────── */
  .uploader-list {
    list-style: none;
    padding: 0;
    margin: 0 0 14px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    overflow: hidden;
  }
  .uploader-row {
    display: grid;
    grid-template-columns: 32px 1fr auto;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
  }
  .uploader-row:last-child {
    border-bottom: none;
  }
  .uploader-avatar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--primary) 14%, transparent);
    color: var(--primary);
    font-size: 13px;
    font-weight: 600;
    -webkit-user-select: none;
    user-select: none;
  }
  .uploader-identity {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .uploader-name {
    font-size: 14px;
    font-weight: 500;
    color: var(--foreground);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .uploader-email {
    font-size: 12px;
    color: var(--muted-foreground);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .uploader-remove {
    padding: 5px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: transparent;
    color: var(--muted-foreground);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition:
      color 0.12s,
      border-color 0.12s,
      background 0.12s;
    font-family: inherit;
  }
  .uploader-remove:hover:not(:disabled) {
    color: var(--destructive);
    border-color: var(--destructive);
    background: color-mix(in srgb, var(--destructive) 8%, transparent);
  }
  .uploader-remove:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  .uploader-add {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .uploader-add input[type="email"] {
    flex: 1;
    min-width: 0;
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    color: var(--foreground);
    font: inherit;
    font-size: 14px;
  }
  .uploader-add input[type="email"]:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 30%, transparent);
  }
  .uploader-add-btn {
    padding: 8px 16px;
    border: 1px solid transparent;
    border-radius: 8px;
    background: var(--primary);
    color: var(--primary-foreground);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition:
      filter 0.12s,
      opacity 0.12s;
    font-family: inherit;
    white-space: nowrap;
  }
  .uploader-add-btn:hover:not(:disabled) {
    filter: brightness(1.08);
  }
  .uploader-add-btn:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  /* ── Publisher ─────────────────────────────────────────────── */
  .publisher-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    margin-bottom: 14px;
  }
  .publisher-card.is-owned {
    border-color: color-mix(in srgb, var(--primary) 40%, var(--border));
    background: color-mix(in srgb, var(--primary) 5%, var(--card));
  }
  .publisher-card-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border-radius: 8px;
    background: var(--muted);
    color: var(--muted-foreground);
    flex-shrink: 0;
  }
  .publisher-card.is-owned .publisher-card-icon {
    background: color-mix(in srgb, var(--primary) 14%, transparent);
    color: var(--primary);
  }
  .publisher-card-text {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .publisher-card-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted-foreground);
  }
  .publisher-card-value {
    font-size: 14px;
    color: var(--foreground);
    font-weight: 500;
  }
  .publisher-link {
    color: var(--primary);
    text-decoration: none;
  }
  .publisher-link:hover {
    text-decoration: underline;
  }

  .publisher-controls {
    display: flex;
    align-items: flex-end;
    gap: 10px;
  }
  .publisher-control-label {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-width: 0;
  }
  .publisher-control-label > span {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted-foreground);
  }
  .publisher-control-label select {
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    color: var(--foreground);
    font: inherit;
    font-size: 14px;
    height: 38px;
  }
  .publisher-control-label select:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 30%, transparent);
  }

  .replaced-by {
    display: flex;
    align-items: flex-end;
    gap: 10px;
    margin-top: 14px;
  }
  .replaced-by-input {
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    color: var(--foreground);
    font: inherit;
    font-size: 14px;
    height: 38px;
  }
  .replaced-by-input:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 30%, transparent);
  }

  .discontinued-banner {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 14px 16px;
    margin-bottom: 20px;
    border: 1px solid
      color-mix(in srgb, var(--pub-error-color) 35%, transparent);
    border-left: 4px solid var(--pub-error-color);
    border-radius: 8px;
    background: color-mix(
      in srgb,
      var(--pub-error-color) 8%,
      var(--background)
    );
    color: var(--pub-default-text-color);
    font-size: 14px;
    line-height: 1.5;
  }
  .discontinued-banner svg {
    color: var(--pub-error-color);
    flex-shrink: 0;
    margin-top: 2px;
  }
  .discontinued-banner-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .discontinued-banner-text strong {
    font-weight: 600;
    color: var(--pub-heading-text-color);
  }
  .discontinued-banner a {
    color: var(--primary);
    font-weight: 500;
    text-decoration: none;
  }
  .discontinued-banner a:hover {
    text-decoration: underline;
  }
  .empty-hint {
    margin: 0;
    padding: 10px 12px;
    border: 1px dashed var(--border);
    border-radius: 8px;
    font-size: 13px;
    color: var(--muted-foreground);
    background: var(--muted);
  }

  .danger-zone h3 {
    color: var(--pub-error-color);
  }
  .danger-btn {
    padding: 8px 16px;
    border: 1px solid var(--pub-error-color);
    border-radius: 6px;
    background: transparent;
    color: var(--pub-error-color);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.12s;
    font-family: inherit;
  }
  .danger-btn:hover {
    background: var(--pub-error-color);
    color: #fff;
  }
  .danger-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  /* ── Confirmation dialog ───────────────────────────────── */
  .confirm-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
  }
  .confirm-dialog {
    background: var(--card, var(--background));
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 24px;
    max-width: 440px;
    width: 90%;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
  }
  .confirm-dialog h3 {
    font-size: 16px;
    font-weight: 600;
    margin: 0 0 10px;
    color: var(--pub-heading-text-color);
  }
  .confirm-dialog h3.result-error {
    color: var(--pub-error-color);
  }
  .confirm-dialog p {
    font-size: 13px;
    color: var(--pub-muted-text-color);
    line-height: 1.55;
    margin: 0 0 16px;
  }
  .confirm-typed-label {
    display: block;
    font-size: 13px;
    color: var(--pub-muted-text-color);
    margin-bottom: 16px;
  }
  .confirm-typed-label code {
    background: var(--muted);
    border: 1px solid var(--border);
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 0.92em;
    color: var(--pub-default-text-color);
    font-family: var(--pub-code-font-family);
  }
  .confirm-input {
    width: 100%;
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--pub-default-text-color);
    font-size: 13px;
    font-family: var(--pub-code-font-family);
    margin-top: 8px;
    box-sizing: border-box;
  }
  .confirm-input:focus {
    outline: none;
    border-color: var(--primary);
    box-shadow: 0 0 0 2px var(--ring);
  }
  .confirm-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }
  .confirm-cancel {
    padding: 8px 16px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: transparent;
    color: var(--pub-muted-text-color);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    font-family: inherit;
  }
  .confirm-cancel:hover {
    color: var(--pub-default-text-color);
    border-color: var(--pub-default-text-color);
  }
  .confirm-proceed {
    padding: 8px 16px;
    border: 1px solid var(--primary);
    border-radius: 6px;
    background: var(--primary);
    color: var(--primary-foreground);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: opacity 0.12s;
  }
  .confirm-proceed:hover {
    opacity: 0.9;
  }
  .confirm-proceed:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Admin tab — scoring ──────────────────────────────── */
  .scoring-admin-status {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
  }
  .scoring-badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
  }
  .scoring-badge.completed {
    background: color-mix(in srgb, var(--success, #4caf50) 15%, transparent);
    color: var(--success, #4caf50);
  }
  .scoring-badge.pending {
    background: color-mix(in srgb, var(--pub-link-text-color) 15%, transparent);
    color: var(--pub-link-text-color);
  }
  .scoring-badge.failed {
    background: color-mix(in srgb, var(--pub-error-color) 15%, transparent);
    color: var(--pub-error-color);
  }
  .scoring-badge.disabled {
    background: var(--muted);
    color: var(--pub-muted-text-color);
  }
  .scoring-detail {
    font-size: 13px;
    color: var(--pub-muted-text-color);
    font-family: var(--pub-code-font-family);
  }
  .scoring-error-details {
    margin-bottom: 12px;
  }
  .scoring-error-details summary {
    cursor: pointer;
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .scoring-error-log {
    margin: 8px 0 0;
    padding: 10px;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 11px;
    font-family: var(--pub-code-font-family);
    overflow-x: auto;
    max-height: 200px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }
  .rescore-btn {
    padding: 6px 16px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: transparent;
    color: var(--pub-link-text-color);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.12s;
    font-family: inherit;
  }
  .rescore-btn:hover {
    background: color-mix(in srgb, var(--pub-link-text-color) 10%, transparent);
  }
  .rescore-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  /* ── Activity Log tab ──────────────────────────────────── */
  .activity-list {
    display: flex;
    flex-direction: column;
  }
  .activity-row {
    display: flex;
    gap: 20px;
    padding: 14px 0;
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .activity-row:last-child {
    border-bottom: none;
  }
  .activity-time {
    flex-shrink: 0;
    width: 100px;
    font-size: 12px;
    color: var(--pub-muted-text-color);
    padding-top: 2px;
  }
  .activity-detail {
    flex: 1;
    min-width: 0;
  }
  .activity-summary {
    margin: 0 0 4px;
    font-size: 14px;
    color: var(--pub-default-text-color);
    line-height: 1.45;
  }
  .activity-agent {
    margin: 0 0 2px;
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }
  .activity-date {
    margin: 0;
    font-size: 11px;
    color: var(--pub-muted-text-color);
  }
</style>
