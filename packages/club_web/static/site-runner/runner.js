import { unpack } from './untar.js';
const params = new URLSearchParams(location.hash.slice(1));
const parentOrigin = params.get('parent');
const session = params.get('session');
if (!parentOrigin || !['http:', 'https:'].includes(new URL(parentOrigin).protocol) || !session) throw Error('Invalid preview context.');
const report = (type, extra = {}) => parent.postMessage({ type, session, ...extra }, parentOrigin);
let accepting = true;
window.addEventListener('message', async event => {
  if (event.origin !== parentOrigin || event.source !== parent || event.data?.session !== session || event.data?.type !== 'install' || !accepting) return;
  accepting = false;
  try {
    const { bytes, etag } = event.data;
    if (!(bytes instanceof ArrayBuffer) || bytes.byteLength > 100*1024*1024 || typeof etag !== 'string') throw Error('Invalid preview content.');
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');
    if (etag !== '"'+hash+'"') throw Error('Site content verification failed.');
    const files=[];
    await unpack(bytes,async(name,data)=>files.push([name,data]));
    const sources=await Promise.all(['parser.js','runtime.js'].map(async name=>{
      const response=await fetch(new URL(name, location.href),{credentials:'omit'});
      if(!response.ok)throw Error('Preview runtime unavailable.');
      return response.text();
    }));
    const frame=document.createElement('iframe');
    frame.sandbox='allow-scripts allow-forms';frame.referrerPolicy='no-referrer';
    const channel=new MessageChannel();
    channel.port1.onmessage=event=>{
      if(event.data?.loaded)report('visible');
      else if(typeof event.data?.error==='string')report('error',{message:event.data.error.slice(0,2000)});
    };
    frame.addEventListener('load',()=>{
      // Only this opaque window receives the port. No network or auth RPC exists.
      frame.contentWindow.postMessage('install','*',[channel.port2]);
      channel.port1.postMessage(files,files.map(([,data])=>data.buffer));
    },{once:true});
    frame.srcdoc='<script>'+sources.join('\n').replaceAll('</script','<\\/script')+'<\/script>';
    document.body.replaceChildren(frame);
    addEventListener('pagehide',()=>channel.port1.close(),{once:true});
  } catch(error) { report('error',{message:error instanceof Error?error.message:'Unable to prepare this site.'}); }
});
report('ready');
