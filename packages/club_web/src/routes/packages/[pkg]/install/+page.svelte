<script lang="ts">
  import { page } from '$app/stores';

  const pkg = $derived($page.params.pkg);
  const serverUrl = $derived(window.location.origin);
</script>

<div class="install-page">
  <h2>Installing</h2>

  <section>
    <h3>1. Add dependency</h3>
    <p>Add to your <code>pubspec.yaml</code>:</p>
    <pre><code class="language-yaml">dependencies:
  {pkg}:
    hosted: {serverUrl}
    version: ^1.0.0</code></pre>

    <p>Or use the command line:</p>
    <pre><code class="language-bash">dart pub add {pkg} --hosted-url {serverUrl}</code></pre>
  </section>

  <section>
    <h3>2. Install</h3>
    <pre><code class="language-bash">dart pub get</code></pre>
  </section>

  <section>
    <h3>3. Import</h3>
    <pre><code class="language-dart">import 'package:{pkg}/{pkg}.dart';</code></pre>
  </section>

  <section>
    <h3>Authentication</h3>
    <p>If you haven't configured authentication yet:</p>
    <pre><code class="language-bash">dart pub token add {serverUrl}</code></pre>
    <p>Or use the CLUB CLI:</p>
    <pre><code class="language-bash">club login {serverUrl}
club setup</code></pre>
  </section>
</div>

<style>
  .install-page section {
    margin-bottom: 2rem;
  }
  pre {
    margin: 0.875rem 0 0;
  }
</style>
