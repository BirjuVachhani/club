<script lang="ts">
  import MarkdownRenderer from '$lib/components/MarkdownRenderer.svelte';

  let { data } = $props();
</script>

<svelte:head>
  <title>Privacy Policy | CLUB</title>
  <meta name="description" content="How a CLUB instance handles your data." />
</svelte:head>

<article class="legal">
  <MarkdownRenderer content={data.markdown} />
</article>

<style>
  .legal {
    max-width: 720px;
    margin: 0 auto;
    padding: 1rem 0 5rem;
    color: var(--foreground);
  }

  @media (max-width: 640px) {
    .legal { padding: 0.5rem 0 3rem; }
  }
</style>
