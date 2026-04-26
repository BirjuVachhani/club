<script lang="ts">
  import { api } from '$lib/api/client';

  interface StatsResponse {
    uptime: {
      startedAt: string;
      uptimeSeconds: number;
    };
    counts: {
      packages: number;
      versions: number;
      users: number;
    };
    disk: {
      tarballs: { bytes: number | null; available: boolean };
      docs: { bytes: number | null; available: boolean };
      database: { bytes: number | null; available: boolean };
      total: { bytes: number | null; available: boolean };
    };
    backends: {
      db: string;
      blob: string;
    };
  }

  let stats = $state<StatsResponse | null>(null);
  let loading = $state(true);
  let error = $state('');

  $effect(() => {
    loadStats();
  });

  async function loadStats() {
    loading = true;
    error = '';
    try {
      stats = await api.get<StatsResponse>('/api/admin/stats');
    } catch {
      error = 'Failed to load server stats.';
    }
    loading = false;
  }

  function formatUptime(seconds: number): string {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    const parts: string[] = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0) parts.push(`${hours}h`);
    if (minutes > 0) parts.push(`${minutes}m`);
    if (parts.length === 0 || secs > 0) parts.push(`${secs}s`);
    return parts.join(' ');
  }

  function formatBytes(bytes: number | null | undefined): string {
    if (bytes == null || bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    const value = bytes / Math.pow(1024, i);
    return `${value.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
  }

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString();
  }

  function backendLabel(backend: string): string {
    switch (backend) {
      case 'filesystem': return 'Filesystem';
      case 's3': return 'S3';
      case 'gcs': return 'Google Cloud Storage';
      case 'sqlite': return 'SQLite';
      case 'postgres': return 'PostgreSQL';
      default: return backend;
    }
  }
</script>

<svelte:head><title>Stats · Admin | club</title></svelte:head>

<div class="stats-page">
  <h2>Stats</h2>
  <p class="subtitle">Server status, package counts, and storage usage.</p>

  {#if loading}
    <div class="loading">Loading stats...</div>
  {:else if error}
    <div class="error-banner">{error}</div>
  {:else if stats}
    <!-- Server -->
    <section class="stats-section">
      <h3>Server</h3>
      <div class="card-grid">
        <div class="stat-card">
          <div class="stat-label">Uptime</div>
          <div class="stat-value">{formatUptime(stats.uptime.uptimeSeconds)}</div>
          <div class="stat-detail">Since {formatDate(stats.uptime.startedAt)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Database</div>
          <div class="stat-value">{backendLabel(stats.backends.db)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Blob Storage</div>
          <div class="stat-value">{backendLabel(stats.backends.blob)}</div>
        </div>
      </div>
    </section>

    <!-- Packages -->
    <section class="stats-section">
      <h3>Packages</h3>
      <div class="card-grid">
        <div class="stat-card">
          <div class="stat-label">Total Packages</div>
          <div class="stat-value">{stats.counts.packages.toLocaleString()}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Versions</div>
          <div class="stat-value">{stats.counts.versions.toLocaleString()}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Users</div>
          <div class="stat-value">{stats.counts.users.toLocaleString()}</div>
        </div>
      </div>
    </section>

    <!-- Storage -->
    <section class="stats-section">
      <h3>Storage</h3>
      <div class="card-grid">
        <div class="stat-card">
          <div class="stat-label">Tarballs</div>
          {#if stats.disk.tarballs.available}
            <div class="stat-value">{formatBytes(stats.disk.tarballs.bytes)}</div>
          {:else}
            <div class="stat-value na">N/A</div>
            <div class="stat-detail">Using {backendLabel(stats.backends.blob)}</div>
          {/if}
        </div>
        <div class="stat-card">
          <div class="stat-label">API Docs</div>
          {#if stats.disk.docs.available}
            <div class="stat-value">{formatBytes(stats.disk.docs.bytes)}</div>
          {:else}
            <div class="stat-value na">N/A</div>
            <div class="stat-detail">No docs generated yet</div>
          {/if}
        </div>
        <div class="stat-card">
          <div class="stat-label">Database</div>
          {#if stats.disk.database.available}
            <div class="stat-value">{formatBytes(stats.disk.database.bytes)}</div>
          {:else}
            <div class="stat-value na">N/A</div>
            <div class="stat-detail">Using {backendLabel(stats.backends.db)}</div>
          {/if}
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Disk Usage</div>
          {#if stats.disk.total.available}
            <div class="stat-value">{formatBytes(stats.disk.total.bytes)}</div>
          {:else}
            <div class="stat-value na">N/A</div>
          {/if}
        </div>
      </div>
    </section>
  {/if}
</div>

<style>
  .stats-page {
    font-size: 14px;
  }

  h2 {
    font-size: 20px;
    font-weight: 600;
    margin: 0 0 6px;
    color: var(--foreground);
  }

  .subtitle {
    margin: 0 0 28px;
    color: var(--muted-foreground);
    line-height: 1.5;
  }

  .stats-section {
    margin-bottom: 28px;
  }

  .stats-section h3 {
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted-foreground);
    margin: 0 0 12px;
  }

  .card-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
  }

  .stat-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 20px;
  }

  .stat-label {
    font-size: 12px;
    font-weight: 500;
    color: var(--muted-foreground);
    margin-bottom: 6px;
  }

  .stat-value {
    font-size: 22px;
    font-weight: 600;
    color: var(--foreground);
    line-height: 1.2;
  }

  .stat-value.na {
    color: var(--muted-foreground);
    font-size: 16px;
  }

  .stat-detail {
    font-size: 12px;
    color: var(--muted-foreground);
    margin-top: 4px;
  }

  .loading {
    color: var(--muted-foreground);
    padding: 40px 0;
    text-align: center;
  }

  .error-banner {
    background: color-mix(in srgb, var(--destructive) 10%, transparent);
    color: var(--destructive);
    border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
    border-radius: 8px;
    padding: 12px 16px;
    font-size: 13px;
  }
</style>
