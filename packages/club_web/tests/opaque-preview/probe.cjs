// Start from club_web: python3 -m http.server 5199 --bind 127.0.0.1
// Run: node tests/opaque-preview/probe.cjs /absolute/path/to/playwright
const { chromium } = require(process.argv[2] || 'playwright');
const assert = require('node:assert/strict');
const { gzipSync } = require('node:zlib');
const path = require('node:path');
function archive(files) {
  const chunks = [];
  for (const [name, text] of Object.entries(files)) {
    const bytes = Buffer.from(text), header = Buffer.alloc(512);
    header.write(name); header.write('0000644\0', 100);
    header.write(bytes.length.toString(8).padStart(11, '0') + '\0', 124);
    header.fill(32, 148, 156); header[156] = 48; header.write('ustar\0', 257);
    header.write(header.reduce((a, b) => a + b, 0).toString(8).padStart(6, '0') + '\0 ', 148);
    chunks.push(header, bytes, Buffer.alloc((512 - bytes.length % 512) % 512));
  }
  return gzipSync(Buffer.concat([...chunks, Buffer.alloc(1024)]));
}
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage();
    await page.route('https://external.example/script.js', route => route.fulfill({
      contentType: 'text/javascript', body: 'document.body.dataset.external="yes";'
    }));
    await page.goto('http://127.0.0.1:5199/tests/opaque-preview/');
    await page.locator('input').setInputFiles({ name: 'site.tar.gz', mimeType: 'application/gzip', buffer: archive({
      'index.html': '<link rel="stylesheet" href="style.css"><img src="image.svg"><h1>Plain site</h1><a href="docs/">Docs</a><script src="https://external.example/script.js"></script><script type="module" src="main.js"></script>',
      'style.css': 'h1{color:rgb(12,34,56)}',
      'image.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="red"/></svg>',
      'main.js': 'import {value} from "./value.js";fetch("data.json").then(r=>r.json()).then(j=>document.body.dataset.local=value+j.value);',
      'value.js': 'export const value="module";', 'data.json': '{"value":"json"}',
      'docs/index.html': '<h1>Docs page</h1><script>fetch("data.json").then(r=>r.json()).then(j=>document.body.dataset.nested=j.value)</script>',
      'docs/data.json': '{"value":"ok"}'
    }) });
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('"loaded"'));
    let frame = page.frames()[1];
    await frame.waitForFunction(() => document.body.dataset.local === 'modulejson' && document.body.dataset.external === 'yes');
    assert.equal(await frame.locator('h1').evaluate(e => getComputedStyle(e).color), 'rgb(12, 34, 56)', 'Local CSS must load');
    assert.ok(await frame.locator('img').evaluate(e => e.complete && e.naturalWidth > 0), 'Local image must decode');
    await page.evaluate(() => {
      const sibling = document.createElement('iframe'); sibling.sandbox = 'allow-scripts'; sibling.srcdoc = '<p>Other preview secret</p>'; document.body.append(sibling);
    });
    const isolation = await frame.evaluate(async () => {
      const denied = async action => { try { await action(); return false; } catch { return true; } };
      return {
        origin: self.origin,
        parent: await denied(() => parent.document.body),
        sibling: await denied(() => parent.frames[1].document.body),
        storage: await denied(() => localStorage.setItem('escape', 'yes')),
        caches: await denied(() => caches.keys()),
        cookie: await denied(() => document.cookie),
        worker: await denied(() => navigator.serviceWorker.register('/sw.js'))
      };
    });
    assert.deepEqual(isolation, { origin: 'null', parent: true, sibling: true, storage: true, caches: true, cookie: true, worker: true }, 'Uploaded code must not access parent, sibling, or origin storage');
    assert.equal(await frame.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      return registration === undefined && (await navigator.serviceWorker.getRegistrations()).length === 0;
    }), true, 'Optional Flutter PWA checks must see no worker without accessing native storage');
    const pwa = await frame.evaluate(async () => {
      function loadServiceWorker() {
        return navigator.serviceWorker.getRegistration().then(registration =>
          registration || navigator.serviceWorker.register('/flutter_service_worker.js'));
      }
      // Flutter attaches catch only after invoking its optional PWA loader.
      await loadServiceWorker().catch(() => {});
      let nativeDenied=false;
      try { Object.getOwnPropertyDescriptor(Navigator.prototype, 'serviceWorker').get.call(navigator); }
      catch { nativeDenied=true; }
      return nativeDenied;
    });
    assert.equal(pwa, true, 'Default Flutter PWA startup must continue while the native worker API remains denied');
    await frame.getByRole('link', { name: 'Docs', exact: true }).click();
    await frame.waitForFunction(() => document.body.dataset.nested === 'ok');
    console.log('PASS: local HTML/CSS/images/modules/fetch, nested pages, external script, opaque isolation');
    await page.goto('http://127.0.0.1:5199/tests/opaque-preview/');
    const archiveRequests = [];
    page.on('request', request => {
      if (request.url().startsWith('https://archive.invalid/')) archiveRequests.push(request.url());
    });
    await page.route('https://archive.invalid/**', route => route.fulfill({ status: 404, body: 'Not found' }));
    await page.locator('input').setInputFiles({ name: 'regressions.tar.gz', mimeType: 'application/gzip', buffer: archive({
      'index.html': `<link rel="canonical" href="canonical.html"><link rel="alternate" href="feed.xml">
        <link rel="icon" href="missing.ico"><link rel="stylesheet" href="missing.css">
        <style>body{background-image:url(missing-background.png)}</style>
        <img id="missing" src="missing.png"><h1>Still renders</h1>
        <script src="classic.js"></script><script src="extensionless"></script>
        <script src="shared.js"></script><script type="module" src="shared.js"></script>
        <script type="module" src="modules/main.js"></script>
        <script>
          import('./modules/value.js').then(m=>document.body.dataset.inlineImport=m.value);
          const image=new Image();image.src='dynamic-missing.png';document.body.append(image);
          const icon=document.createElement('link');icon.rel='icon';icon.setAttribute('href','dynamic-missing.ico');document.head.append(icon);
          const canonical=document.createElement('link');canonical.rel='canonical';canonical.href='dynamic-canonical.html';document.head.append(canonical);
          // The same bytes cached as a classic script must still be validated as a module.
          window.__archiveImport('./classic.js').then(()=>document.body.dataset.strict='wrong',()=>document.body.dataset.strict='rejected');
        </script>`,
      'classic.js': `with ({value: 010}) { document.body.dataset.sloppy=String(value); }
        import('./modules/value.js').then(m=>document.body.dataset.classicImport=m.value);`,
      'extensionless': 'with ({value:"yes"}) { document.body.dataset.extensionless=value; }',
      'shared.js': `document.body.dataset.shared=(document.body.dataset.shared||'')+(function(){return this===undefined?'module':'classic'})();`,
      'modules/main.js': `import {value} from './reexport.js';
        const dynamic=await import('./dynamic.js');
        document.body.dataset.modules=value+dynamic.value;
        document.body.dataset.meta=import.meta.url;`,
      'modules/reexport.js': `export {value} from './value.js';`,
      'modules/value.js': `export const value='module';`,
      'modules/dynamic.js': `export const value='dynamic';`
    }) });
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('"loaded"'));
    frame = page.frames()[1];
    await frame.waitForFunction(() => document.body.dataset.modules === 'moduledynamic' &&
      document.body.dataset.classicImport === 'module' && document.body.dataset.inlineImport === 'module' &&
      document.body.dataset.strict === 'rejected');
    const result = await frame.evaluate(() => ({
      sloppy: document.body.dataset.sloppy, extensionless: document.body.dataset.extensionless,
      shared: document.body.dataset.shared, meta: document.body.dataset.meta,
      canonical: document.querySelector('link[rel="canonical"]').getAttribute('href'),
      alternate: document.querySelector('link[rel="alternate"]').getAttribute('href'),
      dynamicCanonical: document.querySelectorAll('link[rel="canonical"]')[1].getAttribute('href')
    }));
    assert.deepEqual(result, {
      sloppy: '8', extensionless: 'yes', shared: 'classicmodule', meta: 'https://archive.invalid/modules/main.js',
      canonical: 'canonical.html', alternate: 'feed.xml', dynamicCanonical: 'dynamic-canonical.html'
    }, 'Classic grammar, module semantics, mode-specific blobs, and non-resource links must be preserved');
    assert.ok(!archiveRequests.some(url => /canonical|feed\.xml/.test(url)), 'Canonical and alternate links must never be fetched');
    assert.equal(await frame.locator('h1').textContent(), 'Still renders', 'Missing optional assets must not abort page startup');
    console.log('PASS: missing optional assets, non-resource links, sloppy classic scripts, mode-aware cache, static/dynamic modules');
    await page.goto('http://127.0.0.1:5199/tests/opaque-preview/');
    await page.locator('input').setInputFiles(path.resolve(__dirname, '../../../../dummy_data/sites/club_gallery_demo/flutter/site.tar.gz'));
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('"loaded"'));
    frame = page.frames()[1];
    await frame.locator('flt-semantics-placeholder').waitFor({ state: 'attached' });
    await frame.locator('flt-semantics-placeholder').evaluate(e => e.click());
    await frame.getByRole('button', { name: 'Increment counter' }).click();
    await frame.getByText('Counter: 1', { exact: true }).waitFor();
    assert.equal(await frame.evaluate(() => self.origin), 'null', 'Flutter must remain opaque after startup');
    await page.screenshot({ path: '/tmp/club-opaque-flutter.png' });
    console.log('PASS: Flutter CanvasKit counter interaction without allow-same-origin');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
