<script lang="ts">
  import PackageView from '../../_PackageView.svelte';
  import PackageDetailSkeleton from '$lib/components/PackageDetailSkeleton.svelte';
  let { data } = $props();
</script>

{#await data.streamed.detail}
  <PackageDetailSkeleton />
{:then detail}
  <PackageView
    pkg={detail.pkg}
    score={detail.score}
    isLiked={detail.isLiked}
    canAdmin={detail.canAdmin}
  />
{/await}
