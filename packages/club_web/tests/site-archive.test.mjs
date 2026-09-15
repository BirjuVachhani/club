import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { unpack } from '../static/site-runner/untar.js';

function archive(name, body='hello') {
  const header=Buffer.alloc(512);header.write(name);header.write('0000644\0',100);header.write('0000000\0',108);header.write('0000000\0',116);
  header.write(Buffer.byteLength(body).toString(8).padStart(11,'0')+'\0',124);header.fill(32,148,156);header[156]=48;
  header.write('ustar\0',257);header.write('00',263);
  const checksum=header.reduce((a,b)=>a+b,0);header.write(checksum.toString(8).padStart(6,'0')+'\0 ',148);
  const bytes=gzipSync(Buffer.concat([header,Buffer.from(body),Buffer.alloc((512-Buffer.byteLength(body)%512)%512),Buffer.alloc(1024)]));
  return bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length);
}
test('extracts a valid site and rejects traversal and missing start page',async()=>{
  const files=[];await unpack(archive('index.html'),async(name,data)=>files.push([name,new TextDecoder().decode(data)]));
  assert.deepEqual(files,[['index.html','hello']],'Valid files must survive extraction');
  await assert.rejects(()=>unpack(archive('../index.html'),async()=>{}),/Invalid site path/);
  await assert.rejects(()=>unpack(archive('other.html'),async()=>{}),/no start page/);
});
