import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

// Exercise the route's actual startup code without a DOM or preview runner.
const source = readFileSync(new URL('../src/routes/packages/[pkg]/site/[site]/+page.svelte', import.meta.url), 'utf8');
const script = ts.transpileModule(source.match(/<script lang="ts">([\s\S]*?)<\/script>/)[1].replace(/^\s*import .*;$/gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None }
}).outputText;

async function open({ disabled = false, metadata, archiveStatus = 403 }) {
  const calls = [];
  let mount;
  let finished;
  const done = new Promise(resolve => { finished = resolve; });
  const context = vm.createContext({
    onMount: fn => { mount = fn; }, $state: value => value,
    page: { params: { pkg: 'demo_pkg', site: 'demo' }, data: { disableSites: disabled } },
    get: () => ({ user: { id: 'user' } }), auth: {},
    AbortController, URL, TextEncoder, Uint8Array, ArrayBuffer, Response, crypto: globalThis.crypto,
    setTimeout, clearTimeout,
    location: { origin: 'https://club.test', hostname: 'club.test', replace: url => calls.push(['redirect', url]) },
    window: { addEventListener: () => calls.push(['runner']), removeEventListener: () => {} },
    caches: { open: async () => {
      calls.push(['cache']);
      return { match: async () => new Response('cached archive', { headers: { etag: '"old"' } }), delete: async () => calls.push(['delete']) };
    } },
    fetch: async (url, options) => {
      calls.push(['fetch', url, options]);
      return url.endsWith('/archive') ? new Response('', { status: archiveStatus }) : metadata;
    },
    finished
  });
  vm.runInContext(script.replace('void start();', 'void start().finally(finished);'), context);
  mount();
  await done;
  return { calls, failure: vm.runInContext('failure', context), runnerUrl: vm.runInContext('runnerUrl', context) };
}

test('disabled layout blocks direct route before redirect or cached preview', async () => {
  const result = await open({ disabled: true });
  assert.match(result.failure, /Sites are disabled/, 'Direct routes must explain the policy');
  assert.deepEqual(result.calls, [], 'Disabled routes must not fetch or open a runner');
});
test('fresh metadata denial blocks external redirects with stale layout settings', async () => {
  const result = await open({ metadata: Response.json({ error: { code: 'sites_disabled' } }, { status: 403 }) });
  assert.match(result.failure, /Sites are disabled/, 'The server gate must override stale client settings');
  assert.equal(result.calls.length, 1, 'Denied metadata must not access the cache or redirect');
  assert.equal(result.calls[0][2].cache, 'no-store', 'Metadata must be checked freshly');
});
test('cached archive requires successful server revalidation', async () => {
  const result = await open({ metadata: Response.json({ sites: ['demo'], runnerUrl: 'https://runner.test' }) });
  assert.match(result.failure, /Unable to load/, 'Archive denial must fail closed');
  assert.equal(result.runnerUrl, '', 'Cached bytes must not reach the runner after denial');
  assert.ok(result.calls.some(c => c[0] === 'delete'), 'Denied cached archives must be evicted');
  const request = result.calls.find(c => c[0] === 'fetch' && c[1].endsWith('/archive'));
  assert.equal(request[2].headers['If-None-Match'], '"old"', 'Cached previews must revalidate their ETag');
});
test('enabled external sites still redirect', async () => {
  const result = await open({ metadata: Response.json({ sites: ['demo'], urls: { demo: 'https://example.com/' } }) });
  assert.ok(result.calls.some(c => c[0] === 'redirect' && c[1] === 'https://example.com/'), 'Enabled URL sites must preserve redirects');
  assert.equal(result.failure, '', 'Enabled redirects must not fail');
});

test('package sidebar hides Sites when disabled', () => {
  const sidebar = readFileSync(new URL('../src/routes/packages/[pkg]/_PackageView.svelte', import.meta.url), 'utf8');
  assert.ok(sidebar.includes('{#if !page.data.disableSites && siteNames.length}'), 'Sites visibility must honor the global setting');
  assert.ok(sidebar.includes('if (name && !page.data.disableSites) api.get'), 'Disabled sidebars must not request site metadata');
});

test('default same-host preview reaches archive access check without runner configuration', async () => {
  const result = await open({ metadata: Response.json({ sites: ['demo'], runnerUrl: null }) });
  assert.match(result.failure, /Unable to load/, 'Missing runner config must not prevent server revalidation');
  assert.ok(result.calls.some(c => c[0] === 'fetch' && c[1].endsWith('/archive')), 'Default previews must request the archive');
  assert.ok(!source.includes('allow-same-origin'), 'No preview frame may regain origin privileges');
});

test('layout defaults closed when settings are absent or unavailable', async () => {
  const layout = readFileSync(new URL('../src/routes/+layout.ts', import.meta.url), 'utf8');
  const code = ts.transpileModule(layout.replace(/^import .*;$/gm, '').replace('export const load:', 'const load:'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None }
  }).outputText;
  for (const [browser, data, expected] of [
    [false, null, true], [true, null, true], [true, {}, true],
    [true, { disableSites: true }, true], [true, { disableSites: false }, false],
    [true, { disableSites: 'false' }, true]
  ]) {
    const context = vm.createContext({
      browser, URL, exports: {},
      auth: { hydrate: () => {} }, serverVersion: { set: () => {} },
      invalidateAll: () => {}, redirect: () => new Error('Unexpected redirect'),
      fetch: async () => new Response(''),
    });
    vm.runInContext(code, context);
    const result = await vm.runInContext('load', context)({ url: new URL('https://club.test/login'), fetch: async url => {
      if (url === '/api/setup/status') return data === null ? null : Response.json(data);
      return new Response('', { status: 401 });
    } });
    assert.equal(result.disableSites, expected, 'Only explicit false may enable site access');
  }
});
