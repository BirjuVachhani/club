<script lang="ts">
  /**
   * Placeholder layout shown while a package-detail page streams in.
   * Sketches the header, tab bar, content column and metadata sidebar so
   * the page paints its structure immediately instead of a blank area.
   */
  import Skeleton from './Skeleton.svelte';

  const tabs = Array.from({ length: 5 }, (_, i) => i);
  const contentLines = Array.from({ length: 9 }, (_, i) => i);
  const sidebarRows = Array.from({ length: 5 }, (_, i) => i);
</script>

<div class="pd-skeleton">
  <header class="pd-header">
    <div class="pd-title-row">
      <Skeleton width="min(280px, 60%)" height="34px" radius="7px" />
      <Skeleton width="64px" height="22px" radius="6px" />
    </div>
    <Skeleton width="min(420px, 85%)" height="14px" radius="4px" />
  </header>

  <div class="pd-tabs">
    {#each tabs as t (t)}
      <Skeleton width="72px" height="15px" radius="4px" />
    {/each}
  </div>

  <div class="pd-body">
    <div class="pd-content">
      <Skeleton width="45%" height="22px" radius="6px" />
      <div class="pd-lines">
        {#each contentLines as l (l)}
          <Skeleton
            width={l % 3 === 2 ? '60%' : '100%'}
            height="13px"
            radius="4px"
          />
        {/each}
      </div>
    </div>
    <aside class="pd-sidebar">
      {#each sidebarRows as r (r)}
        <div class="pd-side-block">
          <Skeleton width="40%" height="12px" radius="4px" />
          <Skeleton width="80%" height="14px" radius="4px" />
        </div>
      {/each}
    </aside>
  </div>
</div>

<style>
  .pd-skeleton {
    width: 100%;
  }

  .pd-header {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-bottom: 20px;
  }
  .pd-title-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .pd-tabs {
    display: flex;
    gap: 24px;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--border);
  }

  .pd-body {
    display: grid;
    grid-template-columns: 1fr;
    gap: 28px;
    margin-top: 24px;
  }
  @media (min-width: 900px) {
    .pd-body {
      grid-template-columns: minmax(0, 1fr) 260px;
    }
  }

  .pd-content {
    display: flex;
    flex-direction: column;
    gap: 18px;
    min-width: 0;
  }
  .pd-lines {
    display: flex;
    flex-direction: column;
    gap: 11px;
  }

  .pd-sidebar {
    display: flex;
    flex-direction: column;
    gap: 20px;
  }
  .pd-side-block {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
</style>
