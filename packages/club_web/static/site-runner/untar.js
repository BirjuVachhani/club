/** Bounded tar reader supporting USTAR, GNU long names, and PAX paths. */
export async function unpack(buffer, onFile) {
  const reader = new Blob([buffer]).stream().pipeThrough(new DecompressionStream('gzip')).getReader();
  let pending = new Uint8Array(), total = 0, count = 0;
  const decoder = new TextDecoder();
  const seen = new Set();
  async function take(size) {
    if (!Number.isSafeInteger(size) || size < 0 || size > 500 * 1024 * 1024) throw Error('Site is too large.');
    while (pending.length < size) {
      const { value, done } = await reader.read();
      if (done) throw Error('Incomplete site content.');
      total += value.length;
      if (total > 500 * 1024 * 1024) throw Error('Site is too large.');
      const next = new Uint8Array(pending.length + value.length); next.set(pending); next.set(value, pending.length); pending = next;
    }
    const value = pending.slice(0, size); pending = pending.slice(size); return value;
  }
  const text = (b, start, length) => decoder.decode(b.subarray(start, start + length)).replace(/\0.*$/s, '');
  let longName = null, pax = null;
  try {
    while (true) {
      const header = await take(512);
      if (header.every(b => b === 0)) break;
      const expected = parseInt(text(header, 148, 8).trim(), 8);
      const sum = header.reduce((n, b, i) => n + (i >= 148 && i < 156 ? 32 : b), 0);
      if (sum !== expected || ++count > 10000) throw Error('Invalid site archive.');
      const rawSize = text(header, 124, 12).trim();
      if (!/^[0-7]+$/.test(rawSize)) throw Error('Unsupported site entry.');
      const size = parseInt(rawSize, 8), type = header[156];
      const data = await take(size); await take((512 - size % 512) % 512);
      if (type === 76) { longName = decoder.decode(data).replace(/\0.*$/s, ''); continue; }
      if (type === 120) {
        pax = {}; let pos = 0;
        while (pos < data.length) {
          const space = data.indexOf(32, pos); const length = Number(decoder.decode(data.subarray(pos, space)));
          if (space < pos || !Number.isInteger(length) || length <= space-pos+1 || pos+length > data.length) throw Error('Invalid site metadata.');
          const record = decoder.decode(data.subarray(space+1,pos+length-1)); const eq=record.indexOf('=');
          pax[record.slice(0,eq)] = record.slice(eq+1); pos += length;
        }
        if ('size' in pax || 'linkpath' in pax) throw Error('Unsupported site metadata.');
        continue;
      }
      const prefix = text(header,345,155);
      let name = pax?.path ?? longName ?? ((prefix ? prefix+'/' : '') + text(header,0,100));
      pax = null; longName = null;
      if (type === 53) name = name.replace(/\/$/,'');
      if (!name || name.startsWith('/') || /[\\:\x00-\x1f]/.test(name) || name.split('/').some(p=>!p||p==='.'||p==='..') || seen.has(name)) throw Error('Invalid site path.');
      seen.add(name);
      if (type === 53) continue;
      if (type !== 0 && type !== 48) throw Error('Unsupported site entry.');
      await onFile(name, data);
    }
    if (!seen.has('index.html')) throw Error('The site has no start page.');
  } finally { await reader.cancel(); }
}
