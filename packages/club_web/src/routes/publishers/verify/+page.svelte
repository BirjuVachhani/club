<script lang="ts">
  import { goto } from '$app/navigation';
  import { api, ApiError, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { auth } from '$lib/stores/auth';
  import { canVerifyPublisher } from '$lib/utils/permissions';

  /**
   * Two-step verified-publisher creation flow.
   *
   *  step === 'form':     enter domain + display name + optional details
   *  step === 'verify':   server has issued a token; user pastes TXT
   *                       record into their DNS and clicks "Verify now".
   *                       On success we transition to the created publisher.
   *
   * The token only lives in step-'verify' state — nothing is persisted
   * to localStorage. If the user closes the tab the server keeps the
   * pending row alive for its TTL and the user can start over.
   */
  type Step = 'form' | 'verify';

  let step = $state<Step>('form');

  // Form fields
  let domain = $state('');
  let displayName = $state('');
  let description = $state('');
  let websiteUrl = $state('');
  let contactEmail = $state('');

  // Issued by `/verify/start` on step transition
  let challenge = $state<{
    host: string;
    value: string;
    expiresAt: string;
  } | null>(null);

  // Shared error banner
  let message = $state('');
  let tone: 'info' | 'error' | 'success' = $state('info');

  let starting = $state(false);
  let verifying = $state(false);
  let copied = $state<'host' | 'type' | 'value' | null>(null);

  const user = $derived($auth.user);
  const canVerify = $derived(canVerifyPublisher(user));

  function setMsg(text: string, t: typeof tone = 'info') {
    message = text;
    tone = t;
  }

  async function startVerification(e: Event) {
    e.preventDefault();
    if (starting) return;
    const d = domain.trim().toLowerCase();
    if (!d || !displayName.trim()) return;

    starting = true;
    setMsg('');
    try {
      const data = await api.post<{
        domain: string;
        host: string;
        value: string;
        token: string;
        expiresAt: string;
      }>('/api/publishers/verify/start', {
        domain: d,
        displayName: displayName.trim(),
      });
      challenge = {
        host: data.host,
        value: data.value,
        expiresAt: data.expiresAt,
      };
      step = 'verify';
    } catch (err) {
      setMsg(apiErrorMessage(err, 'Failed to start verification.'), 'error');
    } finally {
      starting = false;
    }
  }

  async function completeVerification() {
    if (verifying || !challenge) return;
    verifying = true;
    setMsg('');
    try {
      const pub = await api.post<{
        publisherId: string;
        displayName: string;
      }>('/api/publishers/verify/complete', {
        domain: domain.trim().toLowerCase(),
        displayName: displayName.trim(),
        description: description.trim() || null,
        websiteUrl: websiteUrl.trim() || null,
        contactEmail: contactEmail.trim() || null,
      });
      goto(`/publishers/${pub.publisherId}`);
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        setMsg(
          apiErrorMessage(
            err,
            'The TXT record was not found or does not match yet. Check the host and value, then try again after DNS propagation.',
          ),
          'error',
        );
      } else if (err instanceof ApiError && err.status === 503) {
        setMsg(
          apiErrorMessage(
            err,
            'DNS lookup is temporarily unavailable. Try again in a minute.',
          ),
          'error',
        );
      } else {
        // Other failures are usually expired challenges, permission issues,
        // or conflicts such as the domain already being claimed.
        setMsg(
          apiErrorMessage(
            err,
            'Verification failed. DNS changes can take a few minutes to propagate — try again shortly.',
          ),
          'error',
        );
      }
    } finally {
      verifying = false;
    }
  }

  async function copyToClipboard(text: string, which: 'host' | 'type' | 'value') {
    try {
      await navigator.clipboard.writeText(text);
      copied = which;
      setTimeout(() => (copied = which === copied ? null : copied), 1500);
    } catch {
      // Clipboard API blocked — user can still select and copy by hand.
    }
  }

  function startOver() {
    challenge = null;
    step = 'form';
    setMsg('');
  }
</script>

<svelte:head><title>Verify a publisher | CLUB</title></svelte:head>

<div class="page">
  <header class="page-header">
    <h1>Verify a publisher</h1>
    <p>
      A verified publisher is one whose domain you've proven control of via
      a DNS TXT record. Verified publishers display a badge and can be
      trusted as coming from the domain's owner.
    </p>
  </header>

  {#if !canVerify}
    <div class="empty-state">
      <p>You don't have permission to verify a publisher.</p>
    </div>
  {:else}
    <InlineMessage {message} {tone} />

    {#if step === 'form'}
      <form class="card" onsubmit={startVerification}>
        <h2>Publisher details</h2>
        <p class="sub">
          You'll be asked to prove control of the domain in the next step.
        </p>

        <div class="field">
          <span class="lbl">Domain</span>
          <Input
            bind:value={domain}
            placeholder="example.com"
            autocomplete="off"
            autocorrect="off"
            spellcheck={false}
            disabled={starting}
            required
          />
          <span class="hint">
            Just the hostname — no scheme, no path. Subdomains like
            <code>packages.example.com</code> are fine too.
          </span>
        </div>

        <div class="field">
          <span class="lbl">Display name</span>
          <Input
            bind:value={displayName}
            placeholder="My Team"
            disabled={starting}
            required
          />
        </div>

        <div class="field">
          <span class="lbl">Description (optional)</span>
          <textarea
            rows="3"
            bind:value={description}
            disabled={starting}
            maxlength="4096"
          ></textarea>
        </div>

        <div class="grid-2">
          <div class="field">
            <span class="lbl">Website (optional)</span>
            <Input
              bind:value={websiteUrl}
              placeholder="https://example.com"
              disabled={starting}
            />
          </div>
          <div class="field">
            <span class="lbl">Contact email (optional)</span>
            <Input
              type="email"
              bind:value={contactEmail}
              placeholder="contact@example.com"
              disabled={starting}
            />
          </div>
        </div>

        <div class="actions actions-dual">
          <Button
            variant="outline"
            onclick={() => goto('/my-publishers')}
            disabled={starting}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            disabled={starting || !domain.trim() || !displayName.trim()}
          >
            {starting ? 'Starting...' : 'Continue'}
          </Button>
        </div>
      </form>
    {:else if challenge}
      <div class="card">
        <h2>Add this DNS TXT record</h2>
        <p class="sub">
          Add a new <strong>TXT</strong> record on
          <code>{domain}</code> with the values below. Once it's live,
          return here and click <strong>Verify now</strong>.
        </p>

        <dl class="record">
          <div class="record-row">
            <dt class="record-label">Host</dt>
            <dd class="record-value-cell">
              <code class="record-value">{challenge.host}</code>
              <button
                type="button"
                class="icon-copy-btn"
                title={copied === 'host' ? 'Copied' : 'Copy host'}
                aria-label="Copy host"
                onclick={() => copyToClipboard(challenge!.host, 'host')}
              >
                {#if copied === 'host'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                {/if}
              </button>
            </dd>
          </div>
          <div class="record-row">
            <dt class="record-label">Type</dt>
            <dd class="record-value-cell">
              <code class="record-value">TXT</code>
              <button
                type="button"
                class="icon-copy-btn"
                title={copied === 'type' ? 'Copied' : 'Copy type'}
                aria-label="Copy type"
                onclick={() => copyToClipboard('TXT', 'type')}
              >
                {#if copied === 'type'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                {/if}
              </button>
            </dd>
          </div>
          <div class="record-row">
            <dt class="record-label">Value</dt>
            <dd class="record-value-cell">
              <code class="record-value">{challenge.value}</code>
              <button
                type="button"
                class="icon-copy-btn"
                title={copied === 'value' ? 'Copied' : 'Copy value'}
                aria-label="Copy value"
                onclick={() => copyToClipboard(challenge!.value, 'value')}
              >
                {#if copied === 'value'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                {/if}
              </button>
            </dd>
          </div>
        </dl>

        <div class="ttl-note" role="note">
          <svg class="ttl-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
          <p>
            Token expires <strong>{new Date(challenge.expiresAt).toLocaleString()}</strong>.
            DNS changes usually propagate within a few minutes, but can take
            up to an hour.
          </p>
        </div>

        <div class="actions actions-dual">
          <Button variant="outline" onclick={startOver} disabled={verifying}>
            Start over
          </Button>
          <Button onclick={completeVerification} disabled={verifying}>
            {verifying ? 'Checking DNS...' : 'Verify now'}
          </Button>
        </div>
      </div>
    {/if}
  {/if}
</div>

<style>
  .page {
    width: 100%;
    min-width: 0;
    max-width: 42rem;
    margin: 0 auto;
  }

  .page-header {
    margin-bottom: 1.5rem;
  }

  .page-header h1 {
    margin: 0 0 0.35rem;
    font-size: 1.5rem;
    font-weight: 700;
  }

  .page-header p {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    line-height: 1.6;
  }

  .card {
    padding: 1.5rem;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--card);
  }

  .card h2 {
    margin: 0 0 0.35rem;
    font-size: 1.125rem;
    font-weight: 600;
  }

  .sub {
    margin: 0 0 1.25rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
    margin-bottom: 1rem;
  }

  .lbl {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted-foreground);
  }

  .hint {
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }

  .hint code,
  .sub code {
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0.05rem 0.3rem;
    font-family: var(--font-mono);
    font-size: 0.85em;
  }

  textarea {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 0.5rem 0.625rem;
    font: inherit;
    background: var(--background);
    color: var(--foreground);
    resize: vertical;
  }

  textarea:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 35%, transparent);
  }

  .grid-2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    margin-top: 0.5rem;
  }

  .actions-dual {
    justify-content: space-between;
  }

  .record {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    margin: 0 0 1rem;
  }

  .record-row {
    display: grid;
    grid-template-columns: 72px 1fr;
    align-items: center;
    gap: 0.75rem;
    padding: 0.5rem 0;
    border-bottom: 1px solid var(--border);
  }

  .record-row:last-child {
    border-bottom: none;
  }

  .record-label {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted-foreground);
    margin: 0;
  }

  .record-value-cell {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin: 0;
    min-width: 0;
  }

  .record-value {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--foreground);
    word-break: break-all;
    border: none;
    background: transparent;
    padding: 0;
  }

  .icon-copy-btn {
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--muted-foreground);
    cursor: pointer;
    transition: color 0.15s, background 0.15s, border-color 0.15s;
  }

  .icon-copy-btn:hover {
    color: var(--primary);
    background: var(--accent);
    border-color: var(--border);
  }

  .icon-copy-btn:focus-visible {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px var(--ring);
  }

  .ttl-note {
    display: flex;
    align-items: flex-start;
    gap: 0.55rem;
    margin: 0 0 1rem;
    padding: 0.7rem 0.85rem;
    border: 1px solid color-mix(in srgb, var(--warning) 35%, transparent);
    border-radius: 8px;
    background: color-mix(in srgb, var(--warning) 10%, transparent);
    color: var(--foreground);
  }

  .ttl-note p {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .ttl-note strong {
    font-weight: 600;
  }

  .ttl-icon {
    flex: none;
    margin-top: 0.15rem;
    color: var(--warning);
  }

  .empty-state {
    padding: 2rem;
    border: 1px dashed var(--border);
    border-radius: 12px;
    background: var(--card);
    color: var(--muted-foreground);
    text-align: center;
  }
</style>
