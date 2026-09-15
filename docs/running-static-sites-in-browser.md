# Running a Downloaded Static-Site ZIP Entirely in a Browser Tab

## Executive summary

**Verdict: yes, this is practical today, and WebAssembly is usually not required for the core static-site case.** A browser application can fetch or accept a ZIP, unpack it client-side, persist the extracted files, and expose them to a normal browser browsing context. The most robust architecture is:

**`Fetch/File → ZIP library → CacheStorage/OPFS/IndexedDB → Service Worker → normal HTTPS-like preview URL`**.

A Service Worker can intercept navigations and subresource requests and synthesize `Response` objects from locally stored files. That gives the downloaded site something much closer to ordinary HTTP hosting than `file://`, `blob:`, or `data:` URLs, while keeping everything inside the browser. Service Workers can intercept top-level navigations as well as subresources, and CacheStorage is specifically designed to persist `Request`/`Response` pairs. citeturn24view6turn0search6

For an ordinary static site—HTML, CSS, JavaScript, images, fonts, Wasm modules—**running an actual HTTP server compiled to WebAssembly is unnecessary and generally the wrong abstraction**. A browser WebAssembly module cannot simply call `bind()`/`listen()` and expose a TCP socket as `localhost:3000`; Emscripten explicitly documents that direct TCP sockets are not available in the browser and instead provides WebSocket/proxy-based networking emulation. A Rust `tiny-http` server compiled to Wasm therefore needs a browser-side transport adapter anyway; at that point a Service Worker acting as the HTTP-facing router is simpler. citeturn10search0

If the site genuinely needs **Node.js semantics**—for example a framework dev server, SSR, an npm package, a build step, or application code that uses `node:fs`/`node:http`—the most mature browser-native option is **StackBlitz WebContainers**. Its API boots a browser-hosted Node environment, mounts a virtual filesystem, spawns processes, and emits a `server-ready` event containing a URL that can be loaded into an iframe or tab. WebContainers virtualizes server networking inside the browser rather than opening a conventional OS TCP port. citeturn24view5turn11search0

As of September 2026, the broader “Node compiled to Wasm” landscape is more nuanced than it was a few years ago. There is still no official Node.js distribution that is itself a browser Wasm binary; Node’s official `node:wasi` functionality runs **WASI applications inside Node**, not Node inside a browser. However, emerging projects now run a real Node Linux binary through a Wasm-hosted emulator: **NanoVM/userland.run**, for example, runs Node.js v25 as a RISC-V Linux userspace binary under a small RISC-V interpreter compiled to WebAssembly. This is technically impressive and open source, but it adds an emulation layer and is much less established than WebContainers. citeturn20search6turn22search0

Deno and Bun do not presently offer comparable official “runtime compiled to Wasm and embedded in arbitrary browser pages” products. Deno officially documents the opposite direction—Deno executing WebAssembly and WASI modules—while Bun remains a native runtime based on Zig and JavaScriptCore. Community experiments exist, but they are not the recommended foundation for this use case. citeturn24view0turn24view1turn12search1

The main architectural decision is therefore not “JavaScript versus WebAssembly”; it is:

| Requirement | Recommended architecture | Verdict |
|---|---|---|
| Normal static HTML/CSS/JS site | ZIP extraction + CacheStorage + Service Worker | **Excellent / recommended** |
| Very large static ZIP | Streaming/range-aware ZIP library + worker + Cache/OPFS + Service Worker | **Excellent with engineering safeguards** |
| Static site whose native/Wasm code expects POSIX files | Emscripten FS/WASI-style VFS + Service Worker adapter | **Viable, but specialized** |
| Node-powered site or build/dev server | WebContainers | **Highly viable** |
| Stock Node binary inside Wasm | NanoVM/RISC-V emulation or similar experimental runtimes | **Technically viable; emerging** |
| `tiny-http` or another native HTTP server compiled directly to Wasm | Compile handler logic, but bridge requests through JS/SW | **Possible, rarely worthwhile** |
| Deno runtime itself in browser Wasm | Community/experimental only | **Not recommended** |
| Bun runtime itself in browser Wasm | No established official implementation | **Not currently practical** |
| `blob:`-URL-only hosting | Rewrite HTML/CSS/URLs aggressively | **Only for simple sites** |
| Extract and open through `file://` | Browser-dependent local-file origin behavior | **Avoid** |

Those recommendations follow directly from the browser platform’s networking, origin, storage, and Service Worker models. citeturn15search2turn24view6turn10search0

## Architecture and feasibility verdicts

The strongest cross-browser design treats the browser itself as the “web server.” The ZIP is converted into a collection of URL-addressable resources. A Service Worker is then a request dispatcher:

```mermaid
flowchart LR
    A[ZIP URL or local File] --> B[Fetch / File API]
    B --> C[ZIP parser<br/>zip.js / unzipit / JSZip]
    C --> D[Validation<br/>paths, sizes, entry limits]
    D --> E[CacheStorage / OPFS / IndexedDB]
    E --> F[Service Worker]
    F --> G[/preview/site-id/index.html]
    G --> H[iframe or new browser tab]
    H -->|CSS / JS / images / modules| F
```

This works because a Service Worker's `fetch` event can intercept requests from controlled clients and `respondWith()` an arbitrary `Response`, including one obtained from local browser storage. It therefore acts as a **virtual HTTP origin endpoint**, although it is not an actual socket-based HTTP server. citeturn24view6turn10search3

A useful URL layout is:

```text
https://runner.example/
    app UI

https://runner.example/__sites/7c2e.../index.html
https://runner.example/__sites/7c2e.../assets/app.js
https://runner.example/__sites/7c2e.../assets/site.css
```

The Service Worker can map `/__sites/<id>/<path>` to a key such as `<id>:<path>` in CacheStorage, IndexedDB, or OPFS. Relative URLs such as `./assets/app.js` then work normally because the browser performs ordinary URL resolution before issuing requests. That avoids the central weakness of Blob URLs: Blob URLs represent individual objects and do not naturally form a hierarchical virtual directory tree. The File API does provide `URL.createObjectURL()` for `Blob` and `File` objects, but multi-file websites generally require rewriting references if Blob URLs are the only hosting mechanism. citeturn17search1

**Workbox is optional rather than fundamental.** `workbox-routing` can make Service Worker route matching and handlers more convenient, including navigation routing, but ordinary Service Worker APIs are sufficient. For a specialized preview engine, a small custom fetch handler is often easier to reason about because mapping site IDs, MIME types, SPA fallbacks, CSP headers, and security policy is application-specific. citeturn10search3turn24view6

**Wasm-based filesystem layers are also optional.** WASI provides standardized interfaces through which a host can make system capabilities available to Wasm components, but WASI does not turn a browser into an operating system or automatically give a module arbitrary filesystem/network capabilities. The embedding host decides what is exposed. Emscripten similarly emulates a filesystem for compiled C/C++ software. These are valuable when the program being run needs POSIX-like file APIs, not when JavaScript merely needs to serve HTML files. citeturn24view4turn24view2

A native HTTP library such as Rust's `tiny-http` changes neither limitation. Its request parsing/routing logic can conceptually be compiled to Wasm, but a normal browser still cannot provide it with a listening TCP socket. One workable design would make the Service Worker convert each browser request into a message to the Wasm request handler, receive a status/header/body result, and construct a `Response`. That is technically a “Wasm HTTP server” at the application layer, but **the Service Worker remains the browser-facing transport**. Emscripten's documented browser networking model confirms that ordinary direct TCP is unavailable and that socket compatibility must instead be mapped to browser-supported transports. citeturn10search0

For Node, the architecture is qualitatively different:

```mermaid
flowchart LR
    A[ZIP] --> B[Browser unzip]
    B --> C[WebContainer virtual filesystem]
    C --> D[Node process]
    D --> E[node:http / Vite / Next / custom server]
    E --> F[WebContainer virtual network]
    F --> G[Browser-visible server URL]
    G --> H[iframe / preview tab]
```

The current WebContainer API documentation demonstrates booting a container, mounting a file tree, running package-manager and server processes, and receiving the browser-visible preview URL through `server-ready`. StackBlitz's architectural material describes its networking as a browser-virtualized stack associated with Service Worker/browser primitives rather than a conventional host socket. citeturn24view5turn11search0

## Browser APIs, ZIP extraction, and storage

**Fetch and Streams are fully adequate for acquisition.** A `fetch()` response exposes its body as a `ReadableStream`, so a caller can process downloaded bytes incrementally rather than necessarily buffering the whole response first. `AbortController` provides cancellation. Cross-origin ZIP downloads are subject to CORS: ordinary `fetch()` defaults to CORS mode, and an opaque `no-cors` response does not expose its headers or body to JavaScript, so it cannot be unzipped. citeturn18search0turn18search1turn15search3

For ZIPs already on the user's machine, the baseline **File API** is broadly usable through `<input type="file">` or drag-and-drop; it exposes a user-selected file as a `File`/`Blob` without granting general filesystem access. citeturn17search1

The newer user-visible **File System Access picker APIs** such as `showDirectoryPicker()` should not be treated as a universal requirement. MDN still marks `showDirectoryPicker()` as limited-availability/experimental and requires a secure context plus transient user activation. It can be an excellent Chromium enhancement—for example, “Export site to folder”—but it is a poor portability dependency. citeturn2search0

That should be distinguished from the **Origin Private File System**, or OPFS. OPFS is an origin-private storage filesystem accessed through `navigator.storage.getDirectory()`, requires no user-selected directory, and is broadly supported by modern Chrome/Chromium, Firefox, and Safari; web.dev records support from Chromium 86, Firefox 111, and Safari 15.2. Synchronous file access handles are designed for worker contexts. citeturn0search7

### ZIP decompression choices

The browser's native `CompressionStream`/`DecompressionStream` APIs do **not themselves constitute a ZIP reader**. The standard API operates on compression streams such as gzip and deflate; a `.zip` archive additionally has local headers, a central directory, filenames, metadata, possibly ZIP64/encryption, and independent compressed entries. A ZIP parser is therefore still required. The Compression Streams API has been broadly available across browsers since May 2023 and can be used internally by ZIP libraries to accelerate the actual deflate step. citeturn24view7

**zip.js is the strongest general-purpose choice for a new robust implementation.** Its current project documentation emphasizes large-data handling, Web Streams, worker support, Zip64, split ZIPs, encryption, Deflate64, and parallel compression. Its default browser build can use a Wasm zlib implementation while opportunistically using native Compression Streams. Importantly for untrusted archives, current zip.js rejects path traversal/absolute-path filenames by default and documents additional strictness, CRC, overlap, file-count, and total-uncompressed-size considerations. citeturn19search1turn19search3

**unzipit is attractive where download efficiency matters.** It can work from URLs, `Blob`s, and buffers and supports random-access/range-oriented archive reading, allowing a remote ZIP to be indexed and individual members retrieved without necessarily downloading all archive contents when the server supports the necessary HTTP range behavior. Its author explicitly warns applications to validate archive paths and uncompressed sizes; supported ZIP compression formats are narrower than zip.js and encrypted archives are not its target. citeturn4search1

**JSZip remains the easiest high-level API for smaller archives.** `loadAsync()` accepts a Blob, ArrayBuffer, or byte array, and versions from 3.8 sanitize `..` relative path components against classic Zip Slip traversal. Its own documentation notes important limitations—including unsupported encrypted/multi-volume archives and memory/performance considerations for large results—so it is not my first recommendation for hundreds of megabytes or adversarial archives. citeturn19search2turn19search0

A practical selection is therefore:

| ZIP scenario | Preferred tool | Rationale |
|---|---|---|
| Small/medium trusted static-site ZIP | JSZip or zip.js | Simple implementation |
| Large ZIP | zip.js | Streams/workers/large-file design |
| Remote ZIP where only some members may be needed | unzipit | Range/random-access design |
| Untrusted uploaded ZIP | zip.js plus application limits | Strong current validation controls |
| Need encrypted/Zip64/Deflate64 edge cases | zip.js | Broader ZIP feature coverage |
| Want minimal custom dependency and archive format is constrained | Custom ZIP parser + Compression Streams | Possible, but substantial format/security work |

The library documentation supports these capability differences; performance for any particular archive is workload-, codec-, hardware-, and browser-dependent and should be benchmarked rather than inferred from package-level claims. citeturn19search0turn19search3turn4search1

### Filesystem and persistence layers

For a static previewer, **CacheStorage is often better than pretending the files are POSIX files**. It already persists HTTP `Request`/`Response` objects, including MIME headers, and is available from Service Workers. That maps directly onto the final operation: “given URL X, return response Y.” citeturn0search6turn24view6

**IndexedDB** is a good alternative when richer metadata/indexing is required. It can store substantial structured data, including blobs and binary values, asynchronously and per-origin. citeturn2search3turn2search6

**OPFS** is preferable when the application's internal model genuinely benefits from files and directories or when very large binary assets need file-like access. It is origin-private rather than a user-visible folder. citeturn0search7

For Wasm applications built with Emscripten:

- `MEMFS` is the conventional in-memory filesystem and disappears when the page/runtime is gone.
- `IDBFS` adds persistence by synchronizing an Emscripten filesystem tree with IndexedDB using `FS.syncfs()`.
- `WORKERFS` can expose user-selected `File`/`Blob` objects read-only to worker-hosted Emscripten code without copying their entire contents into MEMFS.
- `WasmFS` moves more filesystem implementation into WebAssembly and is intended as the longer-term high-performance/multithread-friendly replacement for the older JavaScript FS, although Emscripten still documents feature/back-end differences. citeturn24view2

**BrowserFS should now be regarded as legacy.** Its repository states that it was deprecated in March 2024 in favor of the maintained ZenFS fork. BrowserFS remains useful as an architectural example because it emulates Node's `fs` API and includes InMemory, IndexedDB, and ZIP filesystem backends; its README even demonstrates fetching a ZIP and mounting it as a `ZipFS`. For new code, ZenFS is the more appropriate descendant. citeturn24view3

WASI occupies a different layer. It standardizes the contract between a Wasm guest and its host. The host can expose a capability-scoped filesystem, clocks, streams, and other interfaces, but **the browser integration still has to be written or supplied by a runtime**. WASI therefore makes sense when running portable Wasm applications; it is not itself a replacement for Service Workers, CacheStorage, or OPFS. citeturn24view4

## Hosting and runtime options

### Service Worker virtual static hosting

For the stated static-site problem, this approach has the fewest moving parts and the best standards-based portability.

A Service Worker can intercept both navigations and ordinary resource requests. The handler can normalize the requested path, find the extracted entry, set the correct `Content-Type`, and return it. Workbox can provide route abstractions, but it is not required. citeturn24view6turn10search3

Two storage variations are especially useful:

**CacheStorage-backed:** write every extracted file as a `Response` keyed by its preview URL. The fetch handler is nearly a `cache.match(request)`. This is the cleanest design for static content. citeturn0search6

**OPFS/IndexedDB-backed:** store raw files there and construct `Response` objects dynamically. This is better if files are also edited, processed by Wasm, or manipulated through a filesystem abstraction before being served. OPFS and IndexedDB are both governed by origin storage quotas rather than by general native disk access. citeturn0search7turn15search0

An in-memory JavaScript `Map<string, Uint8Array>` also works for short-lived previews, but it needlessly ties the entire expanded site to process memory and provides no persistence. For reloadable/offline use, browser storage is the safer architectural baseline. Browser storage APIs are explicitly designed around origin-managed persistence and quotas. citeturn15search0

### Blob URLs

Blob URLs are useful for a single self-contained HTML document or generated media, and browsers explicitly support creating them from `Blob`/`File` objects. But a ZIP containing an HTML page plus fifty relative assets does not automatically become a Blob-URL directory. A full Blob-only implementation generally has to parse/rewrite HTML, CSS `url()`, module imports, workers, manifests, source maps, dynamically constructed URLs, and possibly application-level fetch requests. That is why it should be regarded as a niche fallback rather than a general static-site host. citeturn17search1

### Wasm server and WASI designs

A Wasm HTTP library can be useful as **request-handling logic**. For example:

```text
Service Worker FetchEvent
        ↓
serialize method/path/headers/body
        ↓
Wasm function / WASI component
        ↓
status + response headers + body
        ↓
new Response(...)
```

That preserves the browser's networking model while letting existing Rust/C server or routing code execute in Wasm. It is technically feasible. What is not feasible in an ordinary page is assuming the Wasm module can expose a raw OS listener and become `http://127.0.0.1:8000` without a browser-specific networking layer. Emscripten documents this TCP limitation explicitly. citeturn10search0

For serving already-static files, that extra request serialization, Wasm runtime, and VFS layer normally provides no benefit over a Service Worker lookup. It becomes rational when the Wasm component actually computes responses, executes an application framework, or reuses substantial pre-existing native server code. This recommendation is an architectural inference from the browser networking and Service Worker models. citeturn10search0turn24view6

### Node.js in the browser

**WebContainers are the practical first choice.** Their current API can mount a `FileSystemTree`, spawn Node/npm processes, and expose an HTTP server through a generated browser URL. The quickstart explicitly demonstrates mounting files, launching a development server, listening for `server-ready`, and assigning the resulting URL to an iframe. citeturn24view5

The important caveat is browser-platform requirements. WebContainers rely heavily on `SharedArrayBuffer` and cross-origin isolation. StackBlitz's detailed browser-support page describes Chromium as fully supported, Firefox support with limitations, and Safari support centered on Safari Technology Preview/beta status; its current marketing page more broadly advertises Chromium, Firefox, and Safari TP. The documentation therefore supports treating **Chromium as the lowest-risk production target**, with Firefox and Safari requiring explicit testing for the exact embedding/network/resource pattern. citeturn16search1turn16search2

`SharedArrayBuffer` itself requires a secure, cross-origin-isolated document in current browsers. That normally means appropriate `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` behavior, which can complicate previews that freely incorporate third-party resources. citeturn17search0turn16search1

There is an important terminology trap around **“node-wasm.”** Search results for that phrase include tools such as `wasm3/node-wasm-run`, but that project runs arbitrary Wasm/WASI modules *using Node*; it is not Node compiled into Wasm. The official Node API similarly provides `node:wasi` so Node can host WASI applications. citeturn20search1turn20search6

An emerging alternative is **NanoVM/userland.run**. Its open-source repository describes an RV64GC RISC-V userspace emulator compiled to WebAssembly that can run an actual Node.js v25 Linux binary, npm tooling, filesystem operations, sockets, and a browser virtual-server bridge. This is much closer to literal “stock Node inside a Wasm-powered browser VM” than traditional Node polyfills. The cost is another CPU-emulation layer and a much younger ecosystem; it is better classified as an advanced/experimental option than the default solution for static ZIP hosting. citeturn22search0turn21search7

A second very recent project, `@foisal/nodebrowser`, advertises a Node.js-style browser runtime backed by a C++ kernel compiled to Wasm, a VFS, process spawning, package installation, and HTTP previewing. Given its extremely recent publication at the time of this research, it should be evaluated as emerging technology rather than assumed to have WebContainers' production history. citeturn21search6

### Deno and Bun

The official Deno documentation says Deno can execute ordinary WebAssembly modules and WASI components. That is **Deno as the Wasm host**, not a supported Deno runtime delivered as a browser Wasm guest. Community discussions have explored browser-Wasm builds and VM/container approaches, but I found no first-party equivalent of WebContainers for embedding Deno in a page. citeturn24view0turn12search1

Likewise, Bun's official runtime is built as a native runtime using Zig and JavaScriptCore. I found no official Bun-in-browser-Wasm runtime suitable for this architecture. It should therefore be classified as unavailable for practical production planning unless a third-party emulator/runtime is deliberately accepted. citeturn24view1

## Security, browser differences, performance, and UX

The biggest security issue is **not ZIP decompression or Wasm—it is browser origin authority**.

If arbitrary downloaded HTML/JavaScript is served at:

```text
https://your-product.example/__sites/untrusted/index.html
```

then without additional isolation it belongs to the same origin as:

```text
https://your-product.example/dashboard
```

because origin is determined by scheme, host, and port, not path. A malicious imported site could consequently interact with resources available to that origin subject to normal browser API restrictions. The same-origin policy makes origin—not a URL prefix—the fundamental boundary. citeturn15search2

For untrusted sites, the preferred architecture is therefore a **dedicated runner origin**, for example:

```text
https://app.example.com/          # trusted product UI

https://preview.example.net/
    __sites/<random-id>/...       # imported sites
```

Keep sensitive application cookies/tokens/storage away from the runner origin. For stronger isolation, embed the preview with an iframe `sandbox` policy. Without `allow-same-origin`, a sandboxed document receives an opaque origin and loses normal origin-bound capabilities such as cookies and local storage; adding `allow-scripts` can selectively restore script execution. This improves containment but can break sites that expect ordinary same-origin storage/fetch semantics. citeturn15search1turn15search2

A separate preview origin generally offers a better compatibility/security balance than trying to run arbitrary sites at the trusted product origin and repair the boundary afterward. This is an architectural inference from the web's origin and sandbox models. citeturn15search1turn15search2

**CORS matters in two places.** First, fetching a remote ZIP for JavaScript processing requires the ZIP server to allow your origin; `no-cors` does not help because its response body is opaque. Second, the imported site's own JavaScript may attempt cross-origin API requests which remain governed by normal CORS rules. Hosting the site locally in a Service Worker does not bypass browser CORS. citeturn18search0turn15search3

**CSP is useful but potentially compatibility-breaking.** You can impose a restrictive Content Security Policy on navigation responses—for example disabling outbound connections through `connect-src`, framing, or dangerous script patterns—but arbitrary static sites often rely on inline scripts, third-party CDNs, workers, Wasm, or dynamic code generation. WebAssembly itself also interacts with CSP controls; current zip.js documentation, for example, notes that its Wasm codec build needs the applicable Wasm-evaluation CSP permission or it falls back to another implementation. citeturn15search1turn19search3

**`file://` should not be the deployment mechanism.** Modern browsers generally treat local `file:` documents as opaque origins, and MDN notes that even files in the same directory can therefore trigger origin/CORS failures; exact treatment remains implementation-dependent. This is one reason JavaScript modules, fetches, workers, and multi-file applications often behave differently when double-clicked from disk than when served through HTTP. citeturn15search2

Archive validation needs to happen **before trusting filenames or decompression sizes**. Current zip.js validates path traversal, absolute paths, drive prefixes, and related unsafe names, but it explicitly leaves application-level caps on total uncompressed size and entry count to the caller. JSZip also sanitizes `..` components in current versions. Regardless of library, enforce an archive-level byte budget, per-entry limits, maximum entry count, and path normalization before committing files. citeturn19search3turn19search2

A good policy is conceptually:

```ts
const MAX_FILES = configuredLimit;          // product-specific
const MAX_TOTAL_BYTES = configuredLimit;    // product-specific
const MAX_FILE_BYTES = configuredLimit;     // product-specific

for (const entry of entries) {
  const path = validateNormalizedRelativePath(entry.filename);

  if (++fileCount > MAX_FILES) throw new Error("Too many files");
  if (entry.uncompressedSize > MAX_FILE_BYTES)
    throw new Error("Entry too large");

  total += entry.uncompressedSize;
  if (total > MAX_TOTAL_BYTES)
    throw new Error("Expanded archive too large");

  // Only now extract/persist it.
}
```

The thresholds are deliberately **unspecified** because the user did not provide a maximum ZIP/site size, target device class, or application threat model. The need for application-level uncompressed-size and entry-count limits is documented by zip.js. citeturn19search3

### Performance and storage

For large archives, avoid unnecessarily holding all of these simultaneously:

```text
compressed ZIP
+ ArrayBuffer copy of ZIP
+ decompressed copies of all entries
+ storage serialization copies
+ rendered browser resources
```

Fetch exposes streaming bodies precisely so applications need not always materialize a full response before processing. zip.js supports Web Streams/workers, while unzipit can use range/random-access behavior for compatible remote archives. JSZip's documentation calls out memory limitations for large in-memory results. citeturn18search0turn19search3turn4search1turn19search0

Decompression is also an excellent candidate for a **Web Worker**, especially when dealing with hundreds or thousands of files. zip.js includes worker support; the native Compression Streams API is itself available in workers. citeturn19search3turn24view7

There is no portable “a browser tab may use exactly X GiB” guarantee that an application should design against. Device memory, browser implementation, process policies, Wasm implementation details, and concurrent tabs all matter. A robust application should enforce its own archive limits and fail gracefully rather than assuming that browser allocation failure is a usable quota mechanism.

Persistent browser storage is similarly quota-managed. Current MDN documentation describes IndexedDB, CacheStorage, and OPFS as sharing browser-managed origin storage. As of the cited 2026 documentation, Chromium-derived browsers may allow an origin up to roughly 60% of total disk in their quota calculation; Safari browser applications use a broadly similar approximately-60% per-origin ceiling on current systems; Firefox best-effort storage uses the lower of 10% of disk or a 10 GiB site-group limit, with substantially larger ceilings when persistent storage is granted. Those figures are upper quota policies rather than promises that free space will actually exist. citeturn15search0

Applications should therefore call `navigator.storage.estimate()` and handle `QuotaExceededError`. `navigator.storage.persist()` can request more durable treatment, but approval policy is browser-dependent: current documentation says Firefox can prompt while Chromium/Safari commonly make heuristic decisions. Users can still explicitly clear site data. citeturn2search1turn2search2turn15search0

### Browser compatibility

| Capability | Chromium | Firefox | Safari | Recommendation |
|---|---|---|---|---|
| Fetch / Streams / File / IndexedDB | Strong support | Strong support | Strong support | Safe baseline. citeturn18search0turn17search1turn2search3 |
| Service Worker / CacheStorage | Strong support | Strong support | Strong support | Safe baseline for HTTPS contexts. citeturn24view6turn0search6 |
| Compression Streams | Supported | Supported | Supported | Baseline since May 2023; still needs ZIP parser. citeturn24view7 |
| OPFS | Supported | Supported | Supported | Good cross-browser persistence layer. citeturn0search7 |
| User-visible FS Access pickers | Best support | Do not depend on universally | Do not depend on universally | Feature-detect; keep optional. citeturn2search0 |
| Wasm | Strong support | Strong support | Strong support | Safe baseline for modules that need it. citeturn23search10 |
| SharedArrayBuffer under isolation | Supported with isolation | Supported with isolation | Supported with isolation constraints | Requires secure/cross-origin-isolated setup. citeturn17search0 |
| WebContainers | Full/support focus | Supported with documented limitations | Safari TP/beta emphasis in detailed docs | Prefer Chromium unless explicitly tested elsewhere. citeturn16search1turn16search2 |

### UX

A well-designed importer should expose distinct stages rather than a single spinner:

```text
Downloading  →  Reading archive  →  Validating
      →  Extracting  →  Saving  →  Starting preview
```

Fetch streaming allows download progress when a usable content length is available, and `AbortController` makes cancellation possible. Archive extraction can report progress based on processed entries or uncompressed bytes; exact APIs vary by ZIP library. citeturn18search0turn19search3

Once the extracted site is stored in CacheStorage, IndexedDB, or OPFS and the application shell/Service Worker are installed, a preview can be designed to work offline. Persistence remains browser-managed and can be evicted unless appropriate persistent-storage treatment is granted or the user explicitly retains the data. citeturn15search0turn0search6

For a reusable product, useful UX features are “Import ZIP,” “Replace site,” “Delete site,” “Storage used,” “Keep offline,” “Open preview in isolated tab,” and “Export files.” `navigator.storage.estimate()` can drive the storage indicator; user-visible File System Access export should be a progressive enhancement rather than the only persistence mechanism. citeturn2search1turn2search0

## Implementation blueprints

The following are the two designs I would prioritize.

**Preferred architecture: ZIP → CacheStorage → Service Worker**

Required pieces:

`Fetch` or File API; zip.js/unzipit/JSZip; CacheStorage; Service Worker; optional IndexedDB for site metadata; optional OPFS for editable/very large files. All core hosting APIs are part of the modern browser platform. citeturn18search0turn17search1turn19search3turn0search6turn24view6

**Download or select the ZIP.**

```ts
async function obtainZip(url?: string, file?: File): Promise<Blob> {
  if (file) return file;

  if (!url) throw new Error("No ZIP source");

  const response = await fetch(url, { mode: "cors" });
  if (!response.ok) {
    throw new Error(`ZIP download failed: HTTP ${response.status}`);
  }

  return response.blob();
}
```

For a large remote ZIP, replace the final full-Blob materialization with the selected library's streaming/range mechanism. Fetch responses are streams, and unzipit/zip.js provide relevant archive access modes. citeturn18search0turn4search1turn19search3

**Read and validate the archive.** With zip.js, illustrative pseudocode is:

```ts
import {
  BlobReader,
  BlobWriter,
  ZipReader,
} from "@zip.js/zip.js";

type SiteFile = {
  path: string;
  blob: Blob;
};

async function extractSite(zipBlob: Blob): Promise<SiteFile[]> {
  const reader = new ZipReader(new BlobReader(zipBlob), {
    // Keep zip.js's filename validation enabled.
  });

  const entries = await reader.getEntries();

  const MAX_FILES = 10_000;              // example product policy, tune it
  const MAX_TOTAL = 500 * 1024 ** 2;     // example only, not a browser limit
  const MAX_SINGLE = 100 * 1024 ** 2;    // example only

  if (entries.length > MAX_FILES) {
    throw new Error("Archive contains too many entries");
  }

  let total = 0;
  const files: SiteFile[] = [];

  for (const entry of entries) {
    if (entry.directory) continue;

    // zip.js already rejects unsafe filenames by default.
    // Perform any additional product-specific normalization here.
    if (entry.uncompressedSize > MAX_SINGLE) {
      throw new Error(`File too large: ${entry.filename}`);
    }

    total += entry.uncompressedSize;
    if (total > MAX_TOTAL) {
      throw new Error("Expanded archive exceeds site limit");
    }

    const blob = await entry.getData(new BlobWriter());
    files.push({ path: entry.filename, blob });
  }

  await reader.close();
  return files;
}
```

zip.js's documented security model provides filename validation while explicitly requiring applications to decide their own total-size and entry-count limits. citeturn19search3

**Map files to browser URLs and persist `Response`s.**

```ts
const MIME: Record<string, string> = {
  html: "text/html; charset=utf-8",
  css: "text/css; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  mjs: "text/javascript; charset=utf-8",
  json: "application/json; charset=utf-8",
  wasm: "application/wasm",
  svg: "image/svg+xml",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  webp: "image/webp",
  ico: "image/x-icon",
  woff: "font/woff",
  woff2: "font/woff2",
};

function contentType(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return MIME[ext] ?? "application/octet-stream";
}

async function installSite(siteId: string, files: SiteFile[]) {
  const cache = await caches.open(`site-${siteId}`);

  await Promise.all(files.map(async ({ path, blob }) => {
    const url =
      `${location.origin}/__sites/${encodeURIComponent(siteId)}/${path}`;

    await cache.put(
      url,
      new Response(blob, {
        headers: {
          "Content-Type": contentType(path),
          "X-Content-Type-Options": "nosniff",
        },
      }),
    );
  }));
}
```

CacheStorage's native unit is exactly the `Request`/`Response` pair needed by a Service Worker, which is why it is especially convenient here. citeturn0search6turn24view6

**Register a Service Worker.**

Application code:

```ts
await navigator.serviceWorker.register("/preview-sw.js", {
  scope: "/",
});

await navigator.serviceWorker.ready;
```

Service Worker:

```ts
// preview-sw.js

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  if (!url.pathname.startsWith("/__sites/")) return;

  event.respondWith(serveSiteRequest(event.request));
});

async function serveSiteRequest(request) {
  // Exact lookup first.
  let response = await caches.match(request);

  if (response) {
    return response;
  }

  // Optional directory-index behavior:
  const url = new URL(request.url);

  if (url.pathname.endsWith("/")) {
    const indexUrl = new URL("index.html", url).href;
    response = await caches.match(indexUrl);
    if (response) return response;
  }

  return new Response("Not found", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
```

The Service Worker `fetch` event and `respondWith()` are specifically intended to allow this kind of intercepted/cache-generated response. citeturn24view6

**Open the site.**

```ts
const preview =
  `/__sites/${encodeURIComponent(siteId)}/index.html`;

iframe.src = preview;

// Or, preferably for untrusted sites,
// open a dedicated preview origin/window.
window.open(preview, "_blank", "noopener");
```

For a single-page application, the SW can optionally return that site's `index.html` for unresolved navigation requests while continuing to return actual `404`s for missing static assets. Whether SPA fallback is correct is **unspecified** because the ZIP/site type was not specified.

A production implementation should put the previewer on an isolated origin when imported code is not fully trusted. The same-origin and sandbox concerns discussed above remain applicable even though the resources came from local browser storage. citeturn15search1turn15search2

**Node-capable architecture: ZIP → WebContainer → Node static server**

Required pieces:

zip.js/unzipit/JSZip; `@webcontainer/api`; cross-origin-isolation-compatible deployment; browser compatibility testing; optionally a custom generated Node static server. WebContainers expose the necessary filesystem/process/server-preview APIs. citeturn24view5turn16search1

**Download and unpack the ZIP in the outer web application.**

Use the same archive acquisition and security-validation process from the first architecture. Instead of writing `Response`s to CacheStorage, convert extracted files into a `FileSystemTree` suitable for `webcontainer.mount()`. citeturn24view5turn19search3

Conceptually:

```ts
const tree = {
  site: {
    directory: {
      "index.html": {
        file: { contents: "<!doctype html>..." },
      },
      assets: {
        directory: {
          "app.js": {
            file: { contents: new Uint8Array(/* ... */) },
          },
        },
      },
    },
  },
};
```

The current API supports mounting file trees and binary file contents. citeturn14search3turn24view5

**Boot WebContainers and mount the site.**

```ts
import { WebContainer } from "@webcontainer/api";

const wc = await WebContainer.boot();

await wc.mount(tree);
```

This is the basic lifecycle shown by the official quickstart. citeturn24view5

**Inject a minimal static server rather than installing one from npm.**

For example:

```js
// server.mjs inside the WebContainer

import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";

const ROOT = path.resolve("/site");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".woff2": "font/woff2",
};

http.createServer(async (req, res) => {
  try {
    const requested = new URL(req.url, "http://local").pathname;

    // Normalize and prevent escaping ROOT.
    let target = path.resolve(ROOT, "." + requested);
    if (!target.startsWith(ROOT + path.sep) && target !== ROOT) {
      res.writeHead(403);
      return res.end("Forbidden");
    }

    const stat = await fs.stat(target);
    if (stat.isDirectory()) {
      target = path.join(target, "index.html");
    }

    const body = await fs.readFile(target);
    const type =
      MIME[path.extname(target).toLowerCase()] ??
      "application/octet-stream";

    res.writeHead(200, {
      "Content-Type": type,
      "X-Content-Type-Options": "nosniff",
    });

    res.end(body);
  } catch {
    res.writeHead(404, {
      "Content-Type": "text/plain; charset=utf-8",
    });
    res.end("Not found");
  }
}).listen(3000);
```

Then start it:

```ts
await wc.spawn("node", ["/server.mjs"]);
```

There is no need to run `npm install` merely to host static files; Node's built-in HTTP and filesystem APIs are enough.

**Receive the browser-visible URL and open it.**

```ts
wc.on("server-ready", (port, url) => {
  console.log(`Virtual server ${port}: ${url}`);
  iframe.src = url;
});
```

The official WebContainers quickstart uses this `server-ready` flow to connect an in-container development server to a browser iframe. citeturn24view5

This second architecture becomes compelling when the ZIP contains more than a static distribution—for example:

```text
package.json
src/
vite.config.js
```

and the product needs to run:

```ts
await wc.spawn("npm", ["install"]);
await wc.spawn("npm", ["run", "dev"]);
```

The WebContainers documentation explicitly supports spawning package managers and Node development servers inside the browser runtime. citeturn16search2turn24view5

For a plain `dist/index.html` ZIP, however, WebContainers are unnecessary overhead compared with Service Worker static hosting.

## Comparison, examples, and prioritized sources

| Approach | Required APIs/Libraries | Pros | Cons | Security issues | Persistence options |
|---|---|---|---|---|---|
| **Service Worker + CacheStorage** | Fetch/File, ZIP library, Service Worker, Cache API | Standards-based; ordinary relative URLs work; low runtime overhead; strong cross-browser baseline; no Node/Wasm required. citeturn24view6turn0search6 | Must implement routing/MIME/fallback rules; SW setup/activation needs care | Imported JS receives runner origin authority unless separately isolated; CORS still applies externally. citeturn15search2turn15search3 | CacheStorage; metadata in IDB; `persist()` best effort. citeturn15search0 |
| **Service Worker + OPFS/IndexedDB** | Fetch/File, ZIP library, SW, OPFS or IDB | Better file-oriented/editable model; handles large structured state; portable across modern major engines. citeturn0search7turn2search3 | More code than CacheStorage because each request must become a `Response` | Same origin concerns; quota/eviction; path validation | OPFS or IndexedDB; persistent-storage request. citeturn15search0 |
| **Workbox static routing** | Same as SW plus Workbox | Convenient routing, navigation handling, cache strategies. citeturn10search3 | Added framework/dependency; generic Workbox abstractions may be more than needed | Same as Service Worker architecture | CacheStorage/IDB/OPFS |
| **Blob URLs** | File/Blob API, ZIP library, URL rewriting | Very small proof of concept; no Service Worker registration | Multi-file relative URLs do not automatically form a directory; extensive rewriting for generic sites | Blob/origin/CSP semantics need care; imported scripts remain untrusted | Usually memory; blobs can originate from persisted stores |
| **BrowserFS/ZenFS + SW** | BrowserFS legacy or ZenFS, ZIP backend, SW | Node-like FS abstraction; convenient for software already expecting `fs` | BrowserFS itself is deprecated; extra abstraction for simple serving. citeturn24view3 | Same untrusted-site issues; FS path validation | IndexedDB and other configured backends |
| **Emscripten FS + SW** | Emscripten/Wasm, MEMFS/IDBFS/WasmFS, SW | Strong option when native C/C++ code already expects POSIX-like files | Large/complex for a normal static site | Wasm guest and imported site need separate threat models; Wasm is not an origin sandbox for JavaScript | IDBFS, plus application-managed OPFS integration. citeturn24view2 |
| **WASI component + SW bridge** | Wasm/WASI host, capability bindings, SW | Reuse portable native response-generation logic; capability-oriented design. citeturn24view4 | Host/browser bindings and request transport still required | Host decides capabilities; unsafe guest/native code still requires hardening | Whatever FS implementation the host exposes |
| **`tiny-http`-style Wasm server** | Rust/C server compiled to Wasm plus JS/SW transport | Reuses server-side routing code | Cannot simply bind browser TCP socket; “server” must be virtualized. citeturn10search0 | Need careful request/response bridge and guest isolation | VFS of choice |
| **WebContainers / Node** | `@webcontainer/api`, SAB/cross-origin isolation, ZIP library | Real Node-like workflow, npm, build tools, dev servers, virtual FS/network. citeturn24view5turn21search3 | Much heavier than static SW host; special browser/header requirements; compatibility differs by browser. citeturn16search1 | Run on isolated preview context; COOP/COEP affects external resources | WebContainer FS during runtime; export/snapshot/application storage as needed |
| **NanoVM / stock Node under Wasm emulator** | NanoVM Wasm runtime, RISC-V Node binary, virtual server adapter | Runs a real Node Linux binary; open-source demonstration that stock Node can execute client-side. citeturn22search0 | CPU emulation overhead; younger ecosystem; large optional runtime/tool images | Guest-runtime and browser-origin boundaries both matter | VFS/application integration; exact product persistence policy varies |
| **Deno-in-Wasm** | Community runtime/emulator | Conceptually achievable | No official embedded browser-Deno equivalent found; Deno's official Wasm docs describe Deno hosting Wasm instead. citeturn24view0turn12search1 | Depends on experimental host | Implementation-specific |
| **Bun-in-Wasm** | No established official solution | — | Bun is currently a native Zig/JavaScriptCore runtime, not an official browser-Wasm runtime. citeturn24view1 | Implementation-specific | Implementation-specific |
| **Extract to disk then `file://`** | File System Access/download | Conceptually simple | `file:` origin behavior is opaque/implementation-dependent; modules/fetch frequently become problematic. citeturn15search2 | Poorly suited as a controlled security boundary | Native files, where permitted |

### Existing projects and demonstrations

The ecosystem contains almost all constituent pieces, although I did **not find a canonical first-party project whose documented primary demo is literally the complete sequence “fetch arbitrary static-site ZIP → unpack it → Service-Worker-host it → automatically open the site.”** That absence is not a technical gap; the architecture is a composition of already-standardized components.

BrowserFS's README contains a particularly relevant partial demonstration: fetch a ZIP, construct a ZIP-backed filesystem, and mount it alongside in-memory and IndexedDB-backed filesystems. BrowserFS is now deprecated in favor of ZenFS, but the example demonstrates that browser ZIP-to-VFS mounting has been practical for years. citeturn24view3

[BrowserFS repository and ZIP/VFS example](https://github.com/jvilk/BrowserFS)

zip.js provides live ZIP-management/read/write demonstrations and a modern stream/worker/Wasm-aware ZIP implementation. citeturn19search1turn19search3

[zip.js repository](https://github.com/gildas-lormeau/zip.js)\
[zip.js documentation](https://gildas-lormeau.github.io/zip.js/)\
[zip.js Zip Manager demo](https://gildas-lormeau.github.io/zip-manager/)

unzipit provides browser examples for reading ZIPs from files and URLs and is especially interesting for its random-access/range-fetch design. citeturn4search1

[unzipit repository](https://github.com/greggman/unzipit)

WebContainers provide the clearest documented **mount files → run server → obtain URL → iframe** flow, making them the closest mature demonstration of the runtime/serve/open half of the requested pipeline. citeturn24view5

[WebContainers quickstart](https://webcontainers.io/guides/quickstart)\
[WebContainers browser support](https://webcontainers.io/guides/browser-support)\
[WebContainers product/API site](https://webcontainers.io/)

NanoVM/userland.run is a noteworthy 2026-era example of a different architecture: a Wasm-hosted RISC-V userspace emulator runs real Node.js and supports a virtual HTTP serving bridge inside the browser. It is valuable as proof that even a stock native-style Node executable can now be brought into a tab through Wasm-mediated emulation, though it should not be confused with compiling Node directly to Wasm. citeturn22search0

[NanoVM / userland.run repository](https://github.com/userland-run/nano)

Runway is another browser IDE built on WebContainers and demonstrates Node projects, persistent virtual filesystems, WebAssembly-compatible languages, and browser-hosted servers in a higher-level application. citeturn20search3

[Runway repository](https://github.com/Badbird5907/runway)

### Prioritized technical sources

| Priority | Source | Why it matters |
|---|---|---|
| **Highest** | [MDN Service Worker `fetch` event](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerGlobalScope/fetch_event) | Definitive browser-facing mechanism for turning local data into normal navigation/subresource responses. citeturn24view6 |
| **Highest** | [MDN Using the Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API/Using_Fetch) | Streaming, CORS, cancellation, response-body behavior. citeturn18search0 |
| **Highest** | [MDN Compression Streams](https://developer.mozilla.org/en-US/docs/Web/API/Compression_Streams_API) | Establishes what native compression APIs do—and why they are not themselves ZIP readers. citeturn24view7 |
| **Highest** | [MDN storage quotas and eviction](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria) | Current Chromium/Firefox/Safari quota and persistence behavior. citeturn15search0 |
| **Highest** | [OPFS overview on web.dev](https://web.dev/articles/origin-private-file-system) | Cross-browser OPFS model, browser support, worker/synchronous access. citeturn0search7 |
| **Highest** | [zip.js documentation](https://gildas-lormeau.github.io/zip.js/) | Current ZIP feature set, streams, workers, Wasm codec, untrusted-input protections. citeturn19search3 |
| **Highest for Node** | [WebContainers quickstart](https://webcontainers.io/guides/quickstart) | Official mount/process/server-ready example. citeturn24view5 |
| **Highest for Wasm FS** | [Emscripten File System API](https://emscripten.org/docs/api_reference/Filesystem-API.html) | MEMFS, IDBFS, WORKERFS, WasmFS and persistence semantics. citeturn24view2 |
| **Highest for WASI** | [WASI.dev](https://wasi.dev/) | Primary WASI project material and capability-oriented host/guest model. citeturn24view4 |
| **Networking constraint** | [Emscripten networking documentation](https://emscripten.org/docs/porting/networking.html) | Explains why a browser Wasm server cannot simply expose normal TCP sockets. citeturn10search0 |
| **Security model** | [WebAssembly.org Security](https://webassembly.org/docs/security/) | Primary description of Wasm's sandbox goals; useful for distinguishing Wasm memory isolation from browser-origin security. citeturn23search10 |
| **Origin security** | [MDN Same-origin policy](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Same-origin_policy) | Critical for deciding whether imported sites may safely share the product origin. citeturn15search2 |
| **Sandbox security** | [MDN CSP `sandbox`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/sandbox) | Documents opaque-origin and script/storage restrictions used to isolate previews. citeturn15search1 |
| **Node/WASI distinction** | [Node.js WASI documentation](https://nodejs.org/api/wasi.html) | Shows that official Node hosts WASI rather than being distributed as a browser-Wasm runtime. citeturn20search6 |
| **Deno/Wasm distinction** | [Deno WebAssembly documentation](https://docs.deno.com/runtime/reference/wasm/) | Shows Deno's supported direction: Deno executing Wasm/WASI. citeturn24view0 |
| **Emerging stock-Node alternative** | [NanoVM](https://github.com/userland-run/nano) | Current open-source example of real Node executing through a RISC-V interpreter compiled to Wasm. citeturn22search0 |

For deeper security background, the WebAssembly research literature is useful precisely because **Wasm's sandbox does not imply that arbitrary native-derived guest code is free of vulnerabilities**. The 2024 review *WebAssembly and Security: a review* surveys 121 security papers, while work such as *Binary Security of WebAssembly* and research on memory-safe Wasm sandboxing examine how native-code vulnerability classes and isolation guarantees translate into Wasm. citeturn23search1turn23search12turn23search0

[WebAssembly and Security: a review](https://arxiv.org/abs/2407.12297)\
[Provably-Safe Multilingual Software Sandboxing using WebAssembly](https://www.usenix.org/conference/usenixsecurity22/presentation/bosamiya)\
[WebAssembly security model](https://webassembly.org/docs/security/)

**Practical recommendation:** build the first version around **zip.js + CacheStorage + a Service Worker on a dedicated preview origin**. That is the best balance of browser portability, performance, offline persistence, understandable security boundaries, and implementation complexity. Add OPFS only if editable/file-oriented workloads make it useful. Add WebAssembly only when some actual computation or existing native code benefits from it. Move to **WebContainers** only when “static site” evolves into “Node project that must build or execute server-side JavaScript.” Generic Wasm HTTP servers, Deno-in-Wasm, Bun-in-Wasm, and CPU-emulated Node runtimes are technically interesting but add complexity without improving the core static-site problem. This prioritization follows from the browser's native Service Worker/storage capabilities, the lack of direct browser TCP sockets for Wasm, and the substantially greater runtime requirements of Node-in-browser systems. citeturn24view6turn0search6turn10search0turn24view5