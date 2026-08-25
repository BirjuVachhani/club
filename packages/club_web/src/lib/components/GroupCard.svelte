<script lang="ts">
  import type { PackageGroupSummary } from "$lib/types/catalog";

  interface Props {
    group: PackageGroupSummary;
    compact?: boolean;
  }

  let { group, compact = false }: Props = $props();
</script>

{#if compact}
  <a
    class="compact-card"
    href={`/groups/${group.slug}`}
    aria-label={`Group: ${group.name}, ${group.packageCount} packages`}
  >
    <span class="compact-stack compact-back" aria-hidden="true"></span>
    <span class="compact-stack compact-middle" aria-hidden="true"></span>
    <span class="compact-surface">
      <span class="compact-meta">
        <span>GROUP</span>
        <span>{group.packageCount} {group.packageCount === 1 ? "package" : "packages"}</span>
      </span>
      <strong>{group.name}</strong>
      {#if group.description}
        <span class="description">{group.description}</span>
      {/if}
    </span>
  </a>
{:else}
  <article
    class="group-row"
    aria-label={`Group: ${group.name}, ${group.packageCount} packages`}
  >
    <a class="group-identity" href={`/groups/${group.slug}`} aria-label={`Open ${group.name} group`}>
      <span class="stack-mark" aria-hidden="true">
        <span class="sheet sheet-back"></span>
        <span class="sheet sheet-middle"></span>
        <span class="sheet sheet-front">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M8 7h8M8 12h8M8 17h5" />
          </svg>
        </span>
      </span>
    </a>

    <div class="row-main">
      <div class="title-line">
        <a class="group-title" href={`/groups/${group.slug}`}>{group.name}</a>
        <span class="group-badge">GROUP</span>
        <span class="title-package-count">
          {group.packageCount} {group.packageCount === 1 ? "package" : "packages"}
        </span>
      </div>
      {#if group.description}
        <p class="description">{group.description}</p>
      {/if}

      {#if group.previewPackages?.length}
        <div class="package-preview" aria-label={`Packages in ${group.name}`}>
          {#each group.previewPackages.slice(0, 7) as pkg (pkg.name)}
            <a class="preview-package" href={`/packages/${pkg.name}`}>
              <span class="preview-heading">
                <span class="preview-name">{pkg.name}</span>
                {#if pkg.version}<span class="preview-version">{pkg.version}</span>{/if}
              </span>
              <span class="preview-description">
                {pkg.description || "No description provided."}
              </span>
              <svg class="package-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="m9 18 6-6-6-6" />
              </svg>
            </a>
          {/each}
        </div>
      {/if}

      {#if group.packageCount > group.previewPackages.length}
        <a class="see-more" href={`/groups/${group.slug}`}>
          See {group.packageCount - group.previewPackages.length} more
          <span aria-hidden="true">→</span>
        </a>
      {/if}
    </div>

  </article>
{/if}

<style>
  /* Browse/search treatment: a true row peer to PackageCard. The small
     paper stack carries the group identity without turning the row into a
     banner or section heading. */
  .group-row {
    display: grid;
    grid-template-columns: 52px minmax(0, 1fr);
    align-items: center;
    gap: 18px;
    min-width: 0;
    padding: 24px 0;
    border-bottom: 1px solid var(--pub-divider-color);
    color: inherit;
    transition: background 0.12s;
  }

  .group-row:first-child { padding-top: 8px; }
  .group-row:last-child { border-bottom: none; }
  .group-row:hover {
    margin: 0 -8px;
    padding-right: 8px;
    padding-left: 8px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--muted) 40%, transparent);
  }
  .group-row:focus-visible {
    border-radius: 10px;
    outline: 2px solid var(--ring);
    outline-offset: 2px;
  }

  .group-identity {
    display: block;
    align-self: start;
    color: inherit;
    text-decoration: none;
  }
  .stack-mark {
    position: relative;
    width: 48px;
    height: 48px;
    flex-shrink: 0;
  }
  .sheet {
    position: absolute;
    width: 40px;
    height: 40px;
    border: 1px solid var(--border);
    border-radius: 7px;
    background: var(--card);
  }
  .sheet-back {
    top: 0;
    left: 8px;
    background: color-mix(in srgb, var(--muted) 65%, var(--card));
  }
  .sheet-middle {
    top: 4px;
    left: 4px;
    background: color-mix(in srgb, var(--muted) 35%, var(--card));
  }
  .sheet-front {
    top: 8px;
    left: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--pub-link-text-color);
    background: var(--card);
  }

  .row-main {
    display: flex;
    min-width: 0;
    flex-direction: column;
    gap: 8px;
  }
  .title-line {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
  }
  .group-title {
    color: var(--pub-link-text-color);
    font-size: 20px;
    font-weight: 600;
    line-height: 1.25;
    letter-spacing: -0.005em;
    overflow-wrap: anywhere;
    text-decoration: none;
  }
  .group-title:hover { text-decoration: underline; }
  .group-badge {
    padding: 3px 7px;
    border: 1px solid color-mix(in srgb, var(--pub-link-text-color) 28%, transparent);
    border-radius: 4px;
    color: var(--pub-link-text-color);
    background: color-mix(in srgb, var(--pub-link-text-color) 9%, transparent);
    font-size: 9px;
    font-weight: 750;
    line-height: 1;
    letter-spacing: 0.08em;
  }
  .title-package-count {
    color: var(--pub-muted-text-color);
    font-size: 12px;
    font-weight: 500;
    white-space: nowrap;
  }

  .description {
    display: -webkit-box;
    overflow: hidden;
    color: var(--pub-default-text-color);
    font-size: 14px;
    line-height: 1.55;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
  }
  .package-preview {
    display: flex;
    flex-direction: column;
    margin-top: 3px;
    border-top: 1px solid var(--pub-divider-color);
  }
  .preview-package {
    display: grid;
    grid-template-columns: minmax(130px, 0.42fr) minmax(0, 1fr) 14px;
    align-items: center;
    gap: 14px;
    min-width: 0;
    padding: 9px 7px;
    border-bottom: 1px solid var(--pub-divider-color);
    color: inherit;
    text-decoration: none;
    transition: background 0.12s;
  }
  .preview-package:hover {
    background: color-mix(in srgb, var(--pub-link-text-color) 6%, transparent);
  }
  .preview-package:focus-visible {
    border-radius: 5px;
    outline: 2px solid var(--ring);
    outline-offset: -2px;
  }
  .preview-heading {
    display: flex;
    align-items: baseline;
    min-width: 0;
    gap: 8px;
  }
  .preview-name {
    overflow: hidden;
    color: var(--pub-link-text-color);
    font-size: 13px;
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .preview-version {
    flex-shrink: 0;
    color: var(--pub-muted-text-color);
    font-family: var(--pub-code-font-family);
    font-size: 11px;
  }
  .preview-description {
    overflow: hidden;
    color: var(--pub-muted-text-color);
    font-size: 12px;
    line-height: 1.35;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .package-chevron {
    color: var(--pub-muted-text-color);
    opacity: 0.55;
    transition: transform 0.14s, opacity 0.14s;
  }
  .preview-package:hover .package-chevron {
    opacity: 1;
    transform: translateX(2px);
  }
  .see-more {
    display: inline-flex;
    align-items: center;
    align-self: flex-start;
    gap: 6px;
    margin-top: 4px;
    color: var(--pub-link-text-color);
    font-size: 12px;
    font-weight: 600;
    text-decoration: none;
  }
  .see-more:hover { text-decoration: underline; }

  /* Home treatment stays card-like because it lives in a grid, not a list. */
  .compact-card {
    position: relative;
    display: flex;
    width: 100%;
    min-width: 0;
    padding-bottom: 10px;
    color: var(--text-primary);
    text-decoration: none;
    isolation: isolate;
  }
  .compact-stack {
    position: absolute;
    inset-inline: 12px;
    height: 100%;
    border: 1px solid var(--border-color);
    border-radius: 10px;
    background: var(--background-secondary);
    pointer-events: none;
  }
  .compact-back { top: 10px; inset-inline: 22px; opacity: 0.55; z-index: -2; }
  .compact-middle { top: 5px; opacity: 0.82; z-index: -1; }
  .compact-surface {
    display: flex;
    flex: 1;
    min-width: 0;
    flex-direction: column;
    gap: 10px;
    padding: 16px;
    border: 1px solid var(--border-color);
    border-radius: 10px;
    background: var(--background-primary);
    transition: border-color 0.15s ease, transform 0.15s ease;
  }
  .compact-card:hover .compact-surface,
  .compact-card:focus-visible .compact-surface {
    border-color: var(--accent-color);
    transform: translateY(-2px);
  }
  .compact-card:focus-visible { outline: none; }
  .compact-meta {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }
  .compact-surface strong { font-size: 16px; line-height: 1.25; }

  @media (min-width: 640px) {
    .group-row:hover {
      margin: 0 -16px;
      padding-right: 16px;
      padding-left: 16px;
    }
  }

  @media (max-width: 560px) {
    .group-row {
      grid-template-columns: 42px minmax(0, 1fr);
      gap: 13px;
    }
    .stack-mark { width: 40px; height: 40px; }
    .sheet { width: 34px; height: 34px; }
    .sheet-back { left: 6px; }
    .sheet-middle { top: 3px; left: 3px; }
    .sheet-front { top: 6px; }
    .preview-package {
      grid-template-columns: minmax(0, 1fr) 14px;
      gap: 8px;
    }
    .preview-description {
      grid-column: 1;
      grid-row: 2;
    }
    .package-chevron {
      grid-column: 2;
      grid-row: 1 / 3;
    }
    .compact-stack { inset-inline: 8px; }
    .compact-back { inset-inline: 16px; }
  }
</style>
