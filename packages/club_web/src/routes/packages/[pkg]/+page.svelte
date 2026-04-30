<script lang="ts">
  import PackageView from './_PackageView.svelte';
  let { data } = $props();
</script>

<PackageView pkg={data.pkg} score={data.score} isLiked={data.isLiked} canAdmin={data.canAdmin} />
