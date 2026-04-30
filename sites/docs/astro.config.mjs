import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'http://docs.club.birju.dev',
  integrations: [
    starlight({
      expressiveCode: {
        themes: ['github-light', 'github-dark'],
        styleOverrides: {
          borderRadius: '14px',
          codeFontFamily: "'Fira Code Variable', 'Fira Code', 'Roboto Mono', Menlo, Consolas, monospace",
          codeFontSize: '0.9rem',
          codeLineHeight: '1.65',
          codePaddingBlock: '1rem',
          codePaddingInline: '1.1rem',
          frames: {
            frameBoxShadowCssValue: 'none',
            showCopyToClipboardButton: true,
            // Remove the terminal/editor window chrome entirely
            editorTabBarBorderBottomColor: 'transparent',
            terminalTitlebarDotsForeground: 'transparent',
            terminalTitlebarBackground: 'transparent',
            terminalTitlebarBorderBottomColor: 'transparent',
          },
        },
      },
      title: 'CLUB',
      description: 'Self-hosted private Dart package repository',
      favicon: '/favicon.svg',
      head: [
        {
          tag: 'script',
          content: `
            document.addEventListener('DOMContentLoaded', () => {
              const host = location.hostname;
              document.querySelectorAll('a[href]').forEach((a) => {
                const raw = a.getAttribute('href');
                if (!raw) return;
                try {
                  const url = new URL(raw, location.href);
                  if (!url.hostname || url.hostname === host) return;
                  a.target = '_blank';
                  const rel = (a.getAttribute('rel') || '').split(/\\s+/).filter(Boolean);
                  if (!rel.includes('noopener')) rel.push('noopener');
                  if (!rel.includes('noreferrer')) rel.push('noreferrer');
                  a.setAttribute('rel', rel.join(' '));
                } catch {}
              });
            });
          `,
        },
      ],
      logo: {
        src: './src/assets/club_full_logo.svg',
        replacesTitle: true,
      },
      social: {
        github: 'https://github.com/BirjuVachhani/club',
      },
      components: {
        ThemeSelect: './src/components/ThemeToggle.astro',
        Head: './src/components/Head.astro',
      },
      customCss: [
        '@fontsource-variable/inter',
        '@fontsource-variable/fira-code',
        './src/styles/custom.css',
      ],
      sidebar: [
        {
          label: 'Overview',
          link: '/',
        },
        {
          label: 'Getting Started',
          autogenerate: { directory: 'getting-started' },
        },
        {
          label: 'Self-Hosting',
          autogenerate: { directory: 'self-hosting' },
        },
        {
          label: 'Guides',
          autogenerate: { directory: 'guides' },
        },
        {
          label: 'CLI',
          autogenerate: { directory: 'cli' },
        },
        {
          label: 'Client SDK',
          autogenerate: { directory: 'sdk' },
        },
        {
          label: 'API Reference',
          autogenerate: { directory: 'api' },
        },
        {
          label: 'Configuration',
          autogenerate: { directory: 'configuration' },
        },
        {
          label: 'Reference',
          autogenerate: { directory: 'reference' },
        },
        {
          label: 'Operations',
          autogenerate: { directory: 'operations' },
        },
      ],
    }),
  ],
});
