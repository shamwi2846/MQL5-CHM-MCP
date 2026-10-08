import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { buildIndex, inspectRasterAsset } from '../src/indexer.mjs';
import { createSearchService, inspectRasterImage } from '../src/search-service.mjs';
import { buildFixture } from './helpers/runtime-fixture.mjs';
import { GENERATOR_VERSION, SEED, pngCase, gifCase } from './helpers/generated-raster.mjs';

const extended=process.env.MQL5_GENERATED_TIER==='extended';
const cases=[...Array.from({length:extended?4096:128},(_,i)=>pngCase(i)),...Array.from({length:extended?4096:64},(_,i)=>gifCase(i))];
function metadata(c){const {bytes,pixels,...rest}=c;return {...rest,expected_pixels:pixels??null};}
async function retainFailure(root,c,error){await writeFile(path.join(root,`${c.category}-${c.number}.bin`),c.bytes);await writeFile(path.join(root,`${c.category}-${c.number}.json`),JSON.stringify({...metadata(c),error:String(error)},null,2));}
async function replace(f,c){
 const revision=path.join(f.root,'revisions',f.databaseHash),asset=f.assets[0];
 await writeFile(path.join(revision,...asset.storageKey.split('/')),c.bytes);
 const db=new DatabaseSync(path.join(revision,'mql5-docs.sqlite'));
 try{db.prepare('UPDATE assets SET sha256=?,byte_count=?,mime_type=?,width=?,height=?,pixel_count=? WHERE asset_id=?').run(c.input_sha256,c.bytes.length,c.category==='PNG'?'image/png':'image/gif',c.width,c.height,c.width*c.height,asset.assetId);}finally{db.close();}
}
test(`generated ${extended?'extended':'fast'} raster oracle and both validators`,async()=>{
 const evidence=await mkdtemp(path.join(tmpdir(),'mql5-generated-raster-'));let failed=false;
 try{
  for(const c of cases)try{
   if(c.valid){assert.deepEqual(inspectRasterImage(c.bytes),{mime:c.category==='PNG'?'image/png':'image/gif',width:c.width,height:c.height});const indexed=inspectRasterAsset(c.bytes,'Technical diagram.'+c.category.toLowerCase());assert.equal(indexed.mimeType,c.category==='PNG'?'image/png':'image/gif');if(c.category==='PNG')assert(c.pixels.flat().every(v=>v>=0&&v<c.palette));}
   else{assert.throws(()=>inspectRasterImage(c.bytes));assert.throws(()=>inspectRasterAsset(c.bytes,'Technical diagram.'+c.category.toLowerCase()));}
  }catch(error){failed=true;await retainFailure(evidence,c,error);throw new Error(`Generator v${GENERATOR_VERSION} seed ${SEED} case ${c.category}/${c.number}; evidence ${evidence}`,{cause:error});}
 }finally{if(!failed)await rm(evidence,{recursive:true,force:true});}
});

test('generated raster indexing preserves valid controls and rejects each malformed category',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'mql5-generated-index-'));let failed=false;
 try{
  await mkdir(path.join(root,'config'));await writeFile(path.join(root,'config/mql5-image-policy.json'),await readFile(new URL('../config/mql5-image-policy.json',import.meta.url)));
  const sources=[];
  for(const id of ['mql5','mql5book','neuronetworksbook']){const bytes=Buffer.from('fixture-'+id);await mkdir(path.join(root,'sources'),{recursive:true});await writeFile(path.join(root,'sources',id+'.chm'),bytes);await mkdir(path.join(root,'extracted',id),{recursive:true});await writeFile(path.join(root,'extracted',id,'topic.htm'),`<div id="help"><h1>${id}</h1>${id==='mql5'?'<img src="diagram.png" alt="Technical diagram">':''}</div>`);sources.push({id,filename:id+'.chm',sha256:createHash('sha256').update(bytes).digest('hex'),expected_topics:1});}
  await writeFile(path.join(root,'corpus.lock.json'),JSON.stringify({schema_version:1,expected_total_topics:3,sources}));
  let priorImage=null;const options={sourceDirectory:'sources',extractedDirectory:'extracted',outputDirectory:'output'};
  const representatives=[...new Map(cases.map(c=>[c.category+'/'+c.mutation,c])).values()];
  for(const c of representatives){
   // GIF controls retain the existing explicit decorative exclusion policy.
   const filename=c.category==='GIF'?'copyright.gif':'diagram.png',image=path.join(root,'extracted/mql5',filename);
   if(priorImage&&priorImage!==image)await rm(priorImage);
   priorImage=image;
   await writeFile(path.join(root,'extracted/mql5/topic.htm'),`<div id="help"><h1>mql5</h1><img src="${filename}" alt="Technical diagram"></div>`);
   await writeFile(image,c.bytes);
   if(c.valid)await buildIndex(root,options);else{const old=await readFile(path.join(root,'output/mql5-docs.sqlite'));await assert.rejects(buildIndex(root,options));assert.deepEqual(await readFile(path.join(root,'output/mql5-docs.sqlite')),old);}
  }
 }catch(error){failed=true;await writeFile(path.join(root,'failure.txt'),String(error));throw new Error('Generated index evidence '+root,{cause:error});}
 finally{if(!failed)await rm(root,{recursive:true,force:true});}
});

test('generated inputs pass runtime and bundled retrieval without exposing invalid bytes',{timeout:300000},async()=>{
 const f=await buildFixture();let service,client,failed=false;
 const server=process.env.MQL5_CHM_TEST_SERVER??path.resolve('build/candidate-v12/app/server.mjs');
 const bootstrap=`import {main} from ${JSON.stringify(pathToFileURL(server).href)};await main({root:${JSON.stringify(f.root)}});`;
 const transport=new StdioClientTransport({command:process.env.MQL5_CHM_TEST_NODE??process.execPath,args:['--input-type=module','--eval',bootstrap],cwd:f.root,stderr:'pipe'});
 try{
  service=await createSearchService({root:f.root});client=new Client({name:'generated-inputs',version:'1.0.0'});await client.connect(transport);
  // Drain expected server diagnostics: an unread stderr pipe can block long tiers.
  transport.stderr?.on('data',()=>{});
  for(const c of cases)try{
   await replace(f,c);
   if(c.valid&&c.category==='PNG')assert.deepEqual(Buffer.from(service.readImage({asset_id:f.assets[0].assetId}).data,'base64'),c.bytes);
   else assert.throws(()=>service.readImage({asset_id:f.assets[0].assetId}));
   const response=await client.callTool({name:'mql5_chm_read_image',arguments:{asset_id:f.assets[0].assetId}});
   if(c.valid&&c.category==='PNG'){assert.notEqual(response.isError,true);assert.deepEqual(Buffer.from(response.content[0].data,'base64'),c.bytes);}
   else{assert.equal(response.isError,true);assert.equal(response.content.some(item=>item.type==='image'),false);}
  }catch(error){failed=true;await retainFailure(f.root,c,error);throw new Error(`Generated retrieval ${c.category}/${c.number}; evidence ${f.root}`,{cause:error});}
 }finally{await client?.close();service?.close();if(!failed)await rm(f.root,{recursive:true,force:true});}
});
