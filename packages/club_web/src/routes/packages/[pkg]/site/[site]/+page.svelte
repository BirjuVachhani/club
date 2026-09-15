<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { get } from 'svelte/store';
  import { auth } from '$lib/stores/auth';

  let status = $state('Loading your site…');
  let progress = $state<number | undefined>();
  let failure = $state('');
  let visible = $state(false);
  let runnerUrl = $state('');
  let frame = $state<HTMLIFrameElement>();
  const digest = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))),v=>v.toString(16).padStart(2,'0')).join('');

  onMount(() => {
    let stop = () => {};
    const start = async () => {
      const controller = new AbortController();
      let timer: ReturnType<typeof setTimeout>;
      let handler: (event: MessageEvent) => void;
      stop=()=>{controller.abort();clearTimeout(timer);if(handler)window.removeEventListener('message',handler);};
      try {
        if(page.data.disableSites)throw Error('Sites are disabled on this server.');
        const pkg=page.params.pkg!, site=page.params.site!;
        const endpoint=`/api/packages/${encodeURIComponent(pkg)}/sites/${encodeURIComponent(site)}/archive`;
        const infoResponse=await fetch(`/api/packages/${encodeURIComponent(pkg)}/sites`,{signal:controller.signal,cache:'no-store'});
        if(infoResponse.status===403 && (await infoResponse.clone().json().catch(()=>null))?.error?.code==='sites_disabled')throw Error('Sites are disabled on this server.');
        if(!infoResponse.ok)throw Error('This preview is unavailable. Sign in and try again.');
        const info=await infoResponse.json();
        if(!info.sites.includes(site))throw Error('This site has not been published yet.');
        const destination=info.urls?.[site];
        if(destination){const target=new URL(destination);if(!['http:','https:'].includes(target.protocol)||target.username||target.password)throw Error('Invalid site URL.');location.replace(target.href);return;}
        const runner=new URL(info.runnerUrl || '/site-runner/index.html',location.origin);
        const owner=get(auth).user?.id ?? 'anonymous';
        const cache=await caches.open('club-site-downloads-'+await digest(owner));
        let cached=await cache.match(endpoint);
        const previous=cached?.headers.get('etag');
        const response=await fetch(endpoint,{signal:controller.signal,cache:'no-store',headers:previous?{'If-None-Match':previous}:{}});
        let bytes: ArrayBuffer, etag: string;
        if(response.status===304 && cached) {
          status='Opening preview…';bytes=await cached.arrayBuffer();etag=previous!;
        } else {
          if(!response.ok) {await cache.delete(endpoint);throw Error('Unable to load this preview. Please try again.');}
          etag=response.headers.get('etag') ?? '';
          const total=Number(response.headers.get('content-length'));
          const chunks: Uint8Array[]=[];let received=0;
          const reader=response.body!.getReader();
          while(true){const {value,done}=await reader.read();if(done)break;received+=value.length;
            if(received>100*1024*1024){await reader.cancel();throw Error('This preview exceeds the supported size.');}
            chunks.push(value);progress=total?Math.min(100,Math.round(received/total*100)):undefined;
          }
          const content=new Uint8Array(received);let offset=0;for(const chunk of chunks){content.set(chunk,offset);offset+=chunk.length;}bytes=content.buffer;
          const actual=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');
          if(etag!==`"${actual}"`)throw Error('Preview verification failed. Please try again.');
          await cache.put(endpoint,new Response(bytes,{headers:{etag,'content-type':'application/gzip'}}));
        }
        status='Preparing preview…';progress=undefined;
        const session=crypto.randomUUID();
        let installed=false;
        handler=event=>{
          if(event.origin!=='null' || event.source!==frame?.contentWindow || event.data?.session!==session)return;
          if(event.data.type==='ready'&&!installed){installed=true;frame!.contentWindow!.postMessage({type:'install',session,bytes,etag},'*',[bytes]);}
          if(event.data.type==='visible'){visible=true;clearTimeout(timer);}
          if(event.data.type==='error'){failure=event.data.message;clearTimeout(timer);}
        };
        window.addEventListener('message',handler);
        runner.hash=new URLSearchParams({parent:location.origin,session}).toString();
        runnerUrl=runner.href;
        timer=setTimeout(()=>{failure='The preview took too long to start. Please try again.';},60000);
      } catch(error) {
        if(!controller.signal.aborted)failure=error instanceof Error?error.message:'Unable to open this preview.';
      }
    };
    void start();
    return ()=>stop();
  });
</script>

<svelte:head><title>{page.params.site} · {page.params.pkg} · Club</title></svelte:head>
<section class="preview" aria-label="Site preview">
  {#if !visible || failure}
    <div class="loading" role="status" aria-live="polite">
      <div class="loading-inner"><img class="mark" src="/club_logo.svg" alt=""/>
        <p class="eyebrow">{page.params.pkg} / {page.params.site}</p>
        <h1>{failure ? 'Unable to open preview' : status}</h1>
        {#if failure}<p class="error">{failure}</p><button onclick={()=>location.reload()}>Try again</button>
        {:else}<div class="progress-track" role="progressbar" aria-label="Loading your site" aria-valuemin="0" aria-valuemax="100" aria-valuenow={progress}><div class="progress-fill" style:transform={`scaleX(${(progress ?? 0) / 100})`}></div></div><p class="caption">{progress === undefined ? 'Just a moment. Your preview will appear here.' : `${progress}%`}</p>{/if}
      </div>
    </div>
  {/if}
  {#if runnerUrl}<iframe bind:this={frame} src={runnerUrl} title={`${page.params.site} preview`} sandbox="allow-scripts allow-forms" referrerpolicy="no-referrer" class:shown={visible && !failure}></iframe>{/if}
</section>
<style>
  .preview{position:fixed;inset:0;z-index:40;background:var(--background);color:var(--foreground);display:flex;flex-direction:column}
  .loading{position:absolute;inset:0;display:grid;place-items:center;padding:24px}.loading-inner{width:min(100%,380px)}.mark{width:48px;height:48px;margin-bottom:32px}.eyebrow{font-size:12px;color:var(--muted-foreground);letter-spacing:.06em;overflow-wrap:anywhere}h1{font-size:clamp(24px,4vw,32px);font-weight:600;letter-spacing:-.035em;margin:12px 0 28px}.progress-track{width:100%;height:5px;background:var(--muted);border-radius:4px;overflow:hidden}.progress-fill{width:100%;height:100%;background:var(--primary);transform-origin:left;transition:transform 250ms ease-out}@media(prefers-reduced-motion:reduce){.progress-fill{transition:none}}.caption{font-size:13px;color:var(--muted-foreground);margin-top:14px}.error{line-height:1.6}button{background:var(--primary);color:var(--primary-foreground);padding:10px 18px;border:0;border-radius:6px;cursor:pointer}button:focus-visible{outline:2px solid var(--primary);outline-offset:4px}iframe{flex:1;width:100%;border:0;opacity:0;min-height:0}iframe.shown{opacity:1}
</style>
