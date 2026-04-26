<script lang="ts">
  import ScoreSection from '$lib/components/ScoreSection.svelte';

  type Section = {
    id: string;
    title: string;
    grantedPoints: number;
    maxPoints: number;
    status: string;
    summary: string;
  };

  const sections: Section[] = [
    {
      id: 'convention',
      title: 'Follow Dart file conventions',
      grantedPoints: 20,
      maxPoints: 30,
      status: 'partial',
      summary: `### [*] 10/10 points: Provide a valid \`pubspec.yaml\`

### [~] 0/5 points: Provide a valid \`README.md\`

The README is shorter than the recommended 400 characters.

### [*] 5/5 points: Provide a valid \`CHANGELOG.md\`

### [*] 5/10 points: Use an OSI-approved license

The license file does not match a recognized OSI-approved license. Consider using a standard license such as MIT, BSD-3, or Apache 2.0.`,
    },
    {
      id: 'documentation',
      title: 'Provide documentation',
      grantedPoints: 10,
      maxPoints: 20,
      status: 'partial',
      summary: `### [~] 0/10 points: 20% or more of the public API has dartdoc comments

43 out of 286 API elements (15.0 %) have documentation comments.

Providing good documentation for libraries, classes, functions, and other API elements improves code readability and helps developers find and use your API. Document at least 20% of the public API elements.

To highlight public API members missing documentation consider enabling the \`public_member_api_docs\` lint.

Some symbols that are missing documentation: \`devkit_ui.CodeToken\`, \`devkit_ui.CodeToken.CodeToken.new\`, \`devkit_ui.CodeToken.type\`, \`devkit_ui.CodeToken.value\`, \`devkit_ui.CodeTokenType\`.

### [*] 10/10 points: Package has an example and has no issues with screenshots`,
    },
    {
      id: 'platform',
      title: 'Platform support',
      grantedPoints: 20,
      maxPoints: 20,
      status: 'passed',
      summary: `### [*] 20/20 points: Supports 6 of 6 possible platforms (**iOS**, **Android**, **Web**, **Windows**, **macOS**, **Linux**)

* ✓ Android
* ✓ iOS
* ✓ Windows
* ✓ Linux
* ✓ macOS
* ✓ Web`,
    },
    {
      id: 'analysis',
      title: 'Pass static analysis',
      grantedPoints: 0,
      maxPoints: 50,
      status: 'failed',
      summary: `### [x] 0/50 points: code has no errors, warnings, lints, or formatting issues

Found 12 issues. Run \`dart analyze\` to see the complete list.`,
    },
    {
      id: 'dependencies',
      title: 'Support up-to-date dependencies',
      grantedPoints: 40,
      maxPoints: 40,
      status: 'passed',
      summary: `### [*] 10/10 points: All of the package dependencies are supported in the latest version

### [*] 20/20 points: Package supports latest stable Dart and Flutter SDKs

### [*] 10/10 points: Compatible with dependency constraint lower bounds`,
    },
  ];

  let expanded = $state<string | null>('documentation');

  function toggle(id: string) {
    expanded = expanded === id ? null : id;
  }
</script>

<div class="preview">
  <header class="preview-head">
    <p class="eyebrow">Component preview</p>
    <h1>ScoreSection</h1>
    <p class="lede">
      Mounted with mock pana output covering passed, partial, and failed states.
      Hover to inspect the inset background; click any row to expand.
    </p>
  </header>

  <section class="canvas">
    <p class="summary-line">
      We analyzed this package <em>just now</em>, and awarded it
      <strong>90</strong> pub points (of a possible 160):
    </p>

    <div class="sections">
      {#each sections as s (s.id)}
        <ScoreSection
          section={s}
          expanded={expanded === s.id}
          ontoggle={() => toggle(s.id)}
        />
      {/each}
    </div>
  </section>
</div>

<style>
  .preview {
    width: 100%;
    max-width: 920px;
    margin: 0 auto;
    padding: 32px 16px 96px;
  }

  .preview-head {
    margin-bottom: 32px;
  }
  .eyebrow {
    margin: 0 0 6px;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--pub-muted-text-color);
  }
  .preview-head h1 {
    margin: 0 0 10px;
    font-size: 28px;
    font-weight: 600;
    color: var(--pub-heading-text-color);
  }
  .lede {
    margin: 0;
    max-width: 60ch;
    font-size: 14px;
    line-height: 1.55;
    color: var(--pub-muted-text-color);
  }

  .canvas {
    padding: 24px;
    border: 1px dashed var(--border);
    border-radius: 14px;
    background: var(--pub-default-background);
  }

  .summary-line {
    padding: 0 0 20px;
    margin: 0 0 4px;
    font-size: 15px;
    line-height: 1.5;
    color: var(--pub-default-text-color);
    border-bottom: 1px solid var(--pub-divider-color);
  }
</style>
