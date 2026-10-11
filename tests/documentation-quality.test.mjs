import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { gradeQualityResponse, measureQuality, validateQualityCases } from "../scripts/DocumentationQualityBenchmark.mjs";
const manifest=JSON.parse(await readFile(new URL('./fixtures/documentation-quality.json',import.meta.url),'utf8'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function imageResponse(c,bytes,m=manifest) {
 const e=c.expected;
 const citation={source_file:m.sources[e.source].filename,title:e.title,topic_id:e.topic_id,section_id:e.image.section_id,source_revision:e.source_revision,corpus_revision:m.corpus_revision,index_revision:m.index_revision};
 return {structuredContent:{asset_id:e.image.asset_id,source:e.source,bytes:bytes.length,sha256:hash(bytes),source_revision:e.source_revision,corpus_revision:m.corpus_revision,index_revision:m.index_revision,primary_topic_citation:citation},content:[{type:'image',mimeType:'image/png',data:bytes.toString('base64')}]};
}
function followingResponse(c,m=manifest) {
 const r=response(c),section=c.expected.image.absent_section;
 r.structuredContent.section_id=section;r.structuredContent.citation.section_id=section;
 r.structuredContent.images=[];r.structuredContent.image_count=0;r.structuredContent.next_image_cursor=null;
 return r;
}
function response(c) {
 const e=c.expected,source=e.source??'mql5',topic=e.topic_id??'mql5:'+'1'.repeat(24),section=c.operation==='read'?e.section_id:null;
 const entry={topic_id:topic,section_id:section,title:e.title??'Other',source,source_revision:manifest.sources[source].sha256,match_kind:'exact'};
 entry.citation={source_file:manifest.sources[source].filename,title:entry.title,topic_id:topic,section_id:section,source_revision:entry.source_revision,corpus_revision:manifest.corpus_revision,index_revision:manifest.index_revision};
 if(c.operation==='search')return {structuredContent:{query:c.arguments.query,source:c.arguments.source,count:e.forbid_exact?0:1,index_sha256:manifest.index_revision,corpus_revision:manifest.corpus_revision,online_check:{recommended:true},results:e.forbid_exact?[]:[entry]},content:[]};
 const images=e.image?[{...e.image,citation:{...entry.citation,section_id:e.image.section_id}}]:[];
 return {structuredContent:{...entry,index_sha256:manifest.index_revision,corpus_revision:manifest.corpus_revision,section_heading:e.section_heading,focus_match:e.focus_match,images,image_count:images.length,next_image_cursor:null},content:[{type:'text',text:e.passage+'\nSource: '+e.topic_id+' | '+e.section_id+' | source '+e.source_revision.slice(0,12)}]};
}
test('quality case manifest freezes all 32 independently sourced cases',()=>{validateQualityCases(manifest);assert.equal(manifest.cases.length,32);});
for(const c of manifest.cases)test(`quality positive control ${c.id}`,()=>assert.deepEqual(gradeQualityResponse(c,response(c),manifest).issues,[]));
for(const mutation of ['revision','source','citation','rank','exact','tool-error','count'])test(`quality rejects ${mutation}`,()=>{
 const c=manifest.cases[0],r=response(c);
 if(mutation==='revision')r.structuredContent.corpus_revision='0'.repeat(64);
 if(mutation==='source')r.structuredContent.results[0].source_revision='0'.repeat(64);
 if(mutation==='citation')r.structuredContent.results[0].citation.topic_id='mql5:'+'0'.repeat(24);
 if(mutation==='rank')r.structuredContent.results.unshift({...structuredClone(r.structuredContent.results[0]),topic_id:'mql5:'+'0'.repeat(24)}),r.structuredContent.count=2;
 if(mutation==='exact')r.structuredContent.results[0].match_kind='fuzzy';
 if(mutation==='tool-error')r.isError=true;
 if(mutation==='count')r.structuredContent.count=3;
 assert.ok(gradeQualityResponse(c,r,manifest).issues.length);
});
for(const mutation of ['passage','section','image','footer','focus'])test(`quality focused evidence rejects ${mutation}`,()=>{
 const c=manifest.cases.find(c=>c.id==='focus-button'),r=response(c);
 if(mutation==='passage')r.content[0].text=r.content[0].text.replace(c.expected.passage,'unrelated passage');
 if(mutation==='section')r.structuredContent.section_id=c.expected.image.absent_section;
 if(mutation==='image')r.structuredContent.images[0].bytes++;
 if(mutation==='footer')r.content[0].text=c.expected.passage;
 if(mutation==='focus')r.structuredContent.focus_match='none';
 assert.ok(gradeQualityResponse(c,r,manifest).issues.length);
});
test('quality nonexistent identifiers cannot borrow exact prefix matches',()=>{
 const c=manifest.cases.find(c=>c.category==='absent'),r=response(c);r.structuredContent.results=[response(manifest.cases[0]).structuredContent.results[0]];r.structuredContent.count=1;
 assert.ok(gradeQualityResponse(c,r,manifest).issues.includes('Misleading exact match for nonexistent identifier'));
});
for(const mutation of ['root','category','id','source','path','count'])test(`quality manifest rejects ${mutation}`,()=>{
 const m=structuredClone(manifest);
 if(mutation==='root')return assert.throws(()=>validateQualityCases([m]));
 if(mutation==='category')m.cases[0].category='focused';
 if(mutation==='id')m.cases[1].id=m.cases[0].id;
 if(mutation==='source')m.cases[0].expected.source_revision='0'.repeat(64);
 if(mutation==='path')m.cases[0].expected.path='foreign.htm';
 if(mutation==='count')m.cases.pop();
 assert.throws(()=>validateQualityCases(m));
});
for(const fault of ['changed-image','image-citation','following-section','sample-revision'])test(`quality measured gate retains ${fault}`,async()=>{
 let calls=0;const m=structuredClone(manifest),button=m.cases.find(c=>c.id==='focus-button'),bytes=Buffer.from('independent measured image control');
 button.expected.image.sha256=hash(bytes);button.expected.image.bytes=bytes.length;
 const client={callTool:async({name,arguments:args})=>{
  if(name==='mql5_chm_read_image'){const image=imageResponse(button,bytes,m);if(fault==='changed-image')image.content[0].data=Buffer.from('changed bytes').toString('base64');if(fault==='image-citation')image.structuredContent.primary_topic_citation.section_id='wrong';return image;}
  const c=m.cases.find(c=>JSON.stringify(c.arguments)===JSON.stringify(args));
  if(!c){const following=followingResponse(button,m);if(fault==='following-section')following.structuredContent.images=[{asset_id:button.expected.image.asset_id}],following.structuredContent.image_count=1;return following;}
  const r=response(c);if(fault==='sample-revision'&&calls++===2)r.structuredContent.index_sha256='0'.repeat(64);return r;
 }};
 const result=await measureQuality(client,m);assert.equal(result.status,'failed');assert.equal(result.cases.length,32);assert.ok(result.cases.every(c=>c.warm_samples_ms.length===9));
 assert.ok(result.cases.some(c=>c.issues.some(issue=>issue.includes(fault==='following-section'?'following section':fault==='sample-revision'?'identity mismatch':'image bytes or citation'))));
});

test('quality retains all failed cases when protocol calls throw',async()=>{const result=await measureQuality({callTool:async()=>{throw new Error('malformed protocol response')}},manifest);assert.equal(result.status,'failed');assert.equal(result.cases.length,32);assert.ok(result.cases.every(c=>c.initial_response.protocol_error==='malformed protocol response'&&c.status==='failed'));});

test('quality accepts a valid bounded image page with a larger total',()=>{
 const c=structuredClone(manifest.cases.find(c=>c.id==='focus-button'));c.arguments.image_limit=1;
 const r=response(c);
 assert.equal(r.structuredContent.images.length,1);
 r.structuredContent.image_count=2;
 r.structuredContent.next_image_cursor='opaque-image-page-cursor';
 assert.deepEqual(gradeQualityResponse(c,r,manifest).issues,[]);
});
test('quality rejects an image page larger than the requested limit',()=>{
 const c=structuredClone(manifest.cases.find(c=>c.id==='focus-button'));c.arguments.image_limit=1;
 const r=response(c);r.structuredContent.images.push({...r.structuredContent.images[0],asset_id:'mql5:asset:'+'0'.repeat(24)});r.structuredContent.image_count=2;
 assert.ok(gradeQualityResponse(c,r,manifest).issues.includes('Invalid image references'));
});
for(const fault of ['count','cursor','images'])test(`quality rejects disabled image evidence ${fault}`,()=>{
 const c=manifest.cases.find(c=>c.id==='focus-volume'),r=response(c);
 assert.equal(c.arguments.include_images,false);
 if(fault==='count')r.structuredContent.image_count=999;
 if(fault==='cursor')r.structuredContent.next_image_cursor='unrequested-image-page';
 if(fault==='images'){r.structuredContent.images=response(manifest.cases.find(c=>c.id==='focus-button')).structuredContent.images;r.structuredContent.image_count=1;}
 assert.ok(gradeQualityResponse(c,r,manifest).issues.includes('Image evidence returned when disabled'));
});
for(const count of [-1,0,1.5,'2',null])test(`quality rejects invalid image total ${JSON.stringify(count)}`,()=>{
 const c=manifest.cases.find(c=>c.id==='focus-button'),r=response(c);
 r.structuredContent.image_count=count;
 assert.ok(gradeQualityResponse(c,r,manifest).issues.includes('Invalid image references'));
});

for(const fault of ['null-search-entry','array-structured-root','null-text-block','object-content','object-images','null-image-entry'])test(`quality records malformed response ${fault}`,async()=>{
 const selected=manifest.cases.find(c=>fault==='null-search-entry'||fault==='array-structured-root'?c.operation==='search':c.id==='focus-button');
 const malformed=response(selected);
 if(fault==='null-search-entry')malformed.structuredContent.results=[null];
 if(fault==='array-structured-root')malformed.structuredContent=[malformed.structuredContent];
 if(fault==='null-text-block')malformed.content=[null];
 if(fault==='object-content')malformed.content={type:'text',text:'invalid container'};
 if(fault==='object-images')malformed.structuredContent.images={};
 if(fault==='null-image-entry')malformed.structuredContent.images=[null];
 const grade=gradeQualityResponse(selected,malformed,manifest);
 assert.ok(grade.issues.length,'Malformed result must fail grading');
 const measured=await measureQuality({callTool:async()=>malformed},manifest);
 assert.equal(measured.status,'failed');assert.equal(measured.cases.length,32);
 const recorded=measured.cases.find(c=>c.id===selected.id);
 assert.equal(recorded.status,'failed');assert.deepEqual(recorded.initial_response,malformed);
 assert.equal(recorded.warm_samples_ms.length,9);assert.equal(recorded.response_sha256.length,9);
});

for(const fault of ['null-image-block','object-image-content','null-following-image','object-following-images'])test(`quality retains malformed image evidence ${fault}`,async()=>{
 const fixtureManifest=structuredClone(manifest),button=fixtureManifest.cases.find(c=>c.id==='focus-button');
 const imageBytes=Buffer.from('controlled independent image fixture');
 button.expected.image.sha256=hash(imageBytes);button.expected.image.bytes=imageBytes.length;
 const imageFault=fault==='null-image-block'||fault==='object-image-content';
 const result=await measureQuality({callTool:async({name,arguments:args})=>{
  if(name==='mql5_chm_read_image')return imageFault?{structuredContent:{},content:fault==='object-image-content'?{}:[null]}:imageResponse(button,imageBytes,fixtureManifest);
  const c=fixtureManifest.cases.find(c=>JSON.stringify(c.arguments)===JSON.stringify(args));
  if(c)return response(c);
  const following=followingResponse(button,fixtureManifest);if(!imageFault)following.structuredContent.images=fault==='object-following-images'?{}:[null];return following;
 }},fixtureManifest);
 assert.equal(result.status,'failed');assert.equal(result.cases.length,32);
 const recorded=result.cases.find(c=>c.id==='focus-button');assert.equal(recorded.status,'failed');
 assert.ok(recorded.issues.includes(imageFault?'Original image bytes or citation changed':'Invalid following-section response'));
 assert.ok(!recorded.issues.includes(imageFault?'Invalid following-section response':'Original image bytes or citation changed'),'Unrelated evidence must remain valid');
});

const extraFaults=['asset_id','source','source_revision','corpus_revision','index_revision','bytes',...['topic_id','section_id','source_file','title','source_revision','corpus_revision','index_revision'].map(field=>'citation-'+field),...['topic_id','section_id','source','source_revision','corpus_revision','index_sha256'].map(field=>'following-'+field),'following-citation','following-count','following-cursor'];
for(const fault of ['none',...extraFaults])test(`quality extra image commitments ${fault}`,async()=>{
 const m=structuredClone(manifest),button=m.cases.find(c=>c.id==='focus-button'),bytes=Buffer.from('independent image identity control');
 button.expected.image.sha256=hash(bytes);button.expected.image.bytes=bytes.length;
 const result=await measureQuality({callTool:async({name,arguments:args})=>{
  if(name==='mql5_chm_read_image') {
   const image=imageResponse(button,bytes,m);
   if(fault.startsWith('citation-'))image.structuredContent.primary_topic_citation[fault.slice(9)]='wrong';
   else if(extraFaults.includes(fault)&&!fault.startsWith('following-'))image.structuredContent[fault]=fault==='bytes'?bytes.length+1:'wrong';
   return image;
  }
  const c=m.cases.find(c=>JSON.stringify(c.arguments)===JSON.stringify(args));if(c)return response(c);
  const following=followingResponse(button,m);
  if(fault==='following-citation')following.structuredContent.citation.topic_id='wrong';
  else if(fault==='following-count')following.structuredContent.image_count=1;
  else if(fault==='following-cursor')following.structuredContent.next_image_cursor='opaque-uninspected-page';
  else if(fault.startsWith('following-'))following.structuredContent[fault.slice(10)]='wrong';
  return following;
 }},m);
 const recorded=result.cases.find(c=>c.id==='focus-button');
 assert.equal(recorded.status,fault==='none'?'passed':'failed',fault);
 assert.equal(result.status,fault==='none'?'passed':'failed');
 assert.ok(result.cases.filter(c=>c.id!=='focus-button').every(c=>c.status==='passed'));
 if(fault!=='none')assert.ok(recorded.issues.length);
});
