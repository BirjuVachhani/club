// In-memory static-site compatibility loader. The opaque sandbox, not these hooks,
// is the security boundary. No authenticated fetch bridge is exposed.
addEventListener('message', function install(event) {
  if (event.source !== parent || event.data !== 'install' || !event.ports[0]) return;
  removeEventListener('message', install);
  const port=event.ports[0];
  port.onmessage=async event=>{
    port.onmessage=null;
    const files=new Map(event.data), urls=new Map(), reverse=new Map();
    const decoder=new TextDecoder();
    const root='https://archive.invalid/';
    let base=root;
    const types={html:'text/html',css:'text/css',js:'text/javascript',mjs:'text/javascript',json:'application/json',wasm:'application/wasm',png:'image/png',jpg:'image/jpeg',svg:'image/svg+xml',woff2:'font/woff2',ttf:'font/ttf',otf:'font/otf'};
    const mime=name=>types[name.split('.').pop()] || 'application/octet-stream';
    const path=(value,from=base)=>{
      const url=new URL(String(value),from);
      if(url.origin!==new URL(root).origin)return null;
      return decodeURIComponent(url.pathname.slice(1));
    };
    const resolving=new Set();
    function resource(value,from=base,mode='raw') {
      const name=path(value,from);
      if(name===null)return String(value).startsWith('//')?new URL(String(value),root).href:String(value);
      const key=mode+':'+name;
      if(urls.has(key))return urls.get(key);
      const data=files.get(name);
      // Missing optional assets fail in the browser, not during page preparation.
      if(!data)return new URL(name,root).href;
      if(resolving.has(key))throw Error('Circular resource dependency is not supported: '+name);
      resolving.add(key);
      try {
        let content=data;
        if(name.endsWith('.css'))content=css(decoder.decode(data),new URL(name,root).href);
        if(mode!=='raw')content=javascript(decoder.decode(data),new URL(name,root).href,mode);
        const url=URL.createObjectURL(new Blob([content],{type:mode==='raw'?mime(name):'text/javascript'}));
        urls.set(key,url);reverse.set(url,name);return url;
      } finally { resolving.delete(key); }
    }
    function javascript(source,from,mode) {
      const tree=acorn.parse(source,{ecmaVersion:'latest',sourceType:mode});
      const edits=[];
      function visit(node) {
        if(!node || typeof node!=='object')return;
        if(node.type==='ImportExpression') {
          edits.push([node.start,node.source.start,'window.__archiveImport(']);
          edits.push([node.source.end,node.source.end,','+JSON.stringify(from)]);
        }
        if(['ImportDeclaration','ExportNamedDeclaration','ExportAllDeclaration'].includes(node.type)&&node.source) {
          const value=node.source.value;
          edits.push([node.source.start,node.source.end,JSON.stringify(resource(value,from,'module'))]);
        }
        if(node.type==='MetaProperty'&&node.meta.name==='import'&&node.property.name==='meta') {
          edits.push([node.start,node.end,'({url:'+JSON.stringify(from)+'})']);
        }
        for(const value of Object.values(node)) {
          if(Array.isArray(value))value.forEach(visit);
          else if(value&&typeof value==='object')visit(value);
        }
      }
      visit(tree);
      for(const [start,end,text] of edits.sort((a,b)=>b[0]-a[0]))source=source.slice(0,start)+text+source.slice(end);
      return source;
    }
    function css(text,from) {
      return text.replace(/@import\s+(["'])([^"']+)\1/g,(_,q,url)=>'@import "'+resource(url,from)+'"').replace(/url\(\s*(["']?)([^)'"\s]+)\1\s*\)/g,(_,q,url)=>`url("${resource(url,from)}")`);
    }
    // Optional PWA setup must reject asynchronously, not throw on the opaque
    // origin's native getter before Flutter can attach its fallback handler.
    const serviceWorker=new EventTarget();
    Object.assign(serviceWorker,{
      controller:null,
      getRegistration:async()=>undefined,
      getRegistrations:async()=>[],
      register:async()=>{throw new DOMException('Service Workers are unavailable in site previews.','NotSupportedError');},
      ready:new Promise(()=>{})
    });
    Object.defineProperty(navigator,'serviceWorker',{value:serviceWorker,configurable:true});
    // ponytail: virtual history state only; address-bar routing is not emulated.
    let historyState=null;
    Object.defineProperty(history,'state',{get:()=>historyState});
    history.replaceState=history.pushState=(state)=>{historyState=structuredClone(state);};
    window.__archiveImport=async(value,from=base)=>import(resource(value,from,'module'));
    const nativeFetch=fetch.bind(window);
    window.fetch=async(input,init)=>{
      let value=input instanceof Request?input.url:String(input);
      const name=reverse.get(value) ?? path(value);
      if(name===null)return nativeFetch(input,init);
      if((init?.method ?? (input instanceof Request?input.method:'GET')).toUpperCase()!=='GET')return new Response('Method not allowed',{status:405});
      const bytes=files.get(name);
      return new Response(bytes ?? 'Not found',{status:bytes?200:404,headers:{'Content-Type':mime(name)}});
    };
    function elementResource(node,value) {
      let mode='raw';
      if(node instanceof HTMLScriptElement)mode=node.type==='module'?'module':'script';
      if(node instanceof HTMLLinkElement) {
        const rel=node.rel.toLowerCase().split(/\s+/);
        if(!rel.some(value=>['stylesheet','icon','apple-touch-icon','apple-touch-icon-precomposed','mask-icon','manifest','preload','modulepreload','prefetch'].includes(value)))return value;
        if(rel.includes('modulepreload'))mode='module';
        else if(rel.includes('preload')&&node.as==='script')mode='script';
      }
      return resource(value,base,mode);
    }
    for(const [type,attribute] of [[HTMLScriptElement,'src'],[HTMLImageElement,'src'],[HTMLLinkElement,'href']]) {
      const descriptor=Object.getOwnPropertyDescriptor(type.prototype,attribute);
      Object.defineProperty(type.prototype,attribute,{...descriptor,set(value){descriptor.set.call(this,elementResource(this,value));}});
    }
    // Let native XHR implement events, response types, and cancellation on Blob URLs.
    const xhrOpen=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(method,url,...rest) {
      return xhrOpen.call(this,method,path(url)===null?url:resource(url),...rest);
    };
    const setAttribute=Element.prototype.setAttribute;
    Element.prototype.setAttribute=function(name,value){
      if((name==='src'&&(this instanceof HTMLScriptElement||this instanceof HTMLImageElement))||(name==='href'&&this instanceof HTMLLinkElement))value=elementResource(this,value);
      return setAttribute.call(this,name,value);
    };
    window.addEventListener('error',event=>port.postMessage({error:event.message}));
    window.addEventListener('unhandledrejection',event=>port.postMessage({error:String(event.reason)}));
    async function open(name) {
      const bytes=files.get(name);if(!bytes)throw Error('Missing page: '+name);
      base=new URL(name,root).href;
      const doc=new DOMParser().parseFromString(decoder.decode(bytes),'text/html');
      const declared=doc.querySelector('base[href]');
      if(declared){const href=declared.getAttribute('href');base=href.startsWith('/')&&!href.startsWith('//')?root:new URL(href,base).href;}
      doc.querySelectorAll('base').forEach(node=>node.remove());
      for(const node of doc.querySelectorAll('[src],link[href]')) {
        const key=node.hasAttribute('src')?'src':'href';
        setAttribute.call(node,key,elementResource(node,node.getAttribute(key)));
      }
      for(const node of doc.querySelectorAll('style'))node.textContent=css(node.textContent,base);
      for(const node of doc.querySelectorAll('[style]'))setAttribute.call(node,'style',css(node.getAttribute('style'),base));
      const scripts=[...doc.querySelectorAll('script')];scripts.forEach(s=>s.remove());
      document.head.replaceChildren(...doc.head.childNodes);document.body.replaceChildren(...doc.body.childNodes);
      const baseTag=document.createElement('base');baseTag.href=base;document.head.prepend(baseTag);
      for(const original of scripts) {
        const script=document.createElement('script');
        for(const attr of original.attributes)setAttribute.call(script,attr.name,attr.value);
        const executable=!original.type||['module','text/javascript','application/javascript'].includes(original.type);
        script.textContent=executable?javascript(original.textContent,base,original.type==='module'?'module':'script'):original.textContent;
        const loaded=(script.src||script.type==='module')?new Promise((resolve,reject)=>{script.onload=resolve;script.onerror=()=>reject(Error('Script failed: '+script.src));}):Promise.resolve();
        document.body.append(script);await loaded;
      }
      port.postMessage({loaded:name,opaque:self.origin==='null'});
    }
    document.addEventListener('click',event=>{
      const link=event.target.closest?.('a[href]');if(!link)return;
      const name=path(link.getAttribute('href'));if(name===null)return;
      event.preventDefault();const target=files.has(name)?name:files.has(name+'/index.html')?name+'/index.html':name.endsWith('/')?name+'index.html':name+'.html';
      open(target).catch(error=>port.postMessage({error:String(error)}));
    });
    open('index.html').catch(error=>port.postMessage({error:String(error)}));
  };
},false);
