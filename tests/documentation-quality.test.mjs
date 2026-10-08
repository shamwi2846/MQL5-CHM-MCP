import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { gradeQualityResponse, measureQuality, validateQualityCases } from "../scripts/DocumentationQualityBenchmark.mjs";
const manifest=JSON.parse(await readFile(new URL('./fixtures/documentation-quality.json',import.meta.url),'utf8'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function response(c) {
 const e=c.expected,source=e.source??'mql5',topic=e.topic_id??'mql5:'+'1'.repeat(24),section=c.operation==='read'?e.section_id:null;
 const entry={topic_id:topic,section_id:section,title:e.title??'Other',source,source_revision:manifest.sources[source].sha256,match_kind:'exact'};
 entry.citation={source_file:manifest.sources[source].filename,title:entry.title,topic_id:topic,section_id:section,source_revision:entry.source_revision,corpus_revision:manifest.corpus_revision,index_revision:manifest.index_revision};
 if(c.operation==='search')return {structuredContent:{query:c.arguments.query,source:c.arguments.source,count:e.forbid_exact?0:1,index_sha256:manifest.index_revision,corpus_revision:manifest.corpus_revision,online_check:{recommended:true},results:e.forbid_exact?[]:[entry]},content:[]};
 const images=e.image?[{...e.image,citation:{...entry.citation,section_id:e.image.section_id}}]:[];
 return {structuredContent:{...entry,index_sha256:manifest.index_revision,corpus_revision:manifest.corpus_revision,section_heading:e.section_heading,focus_match:e.focus_match,images,image_count:images.length},content:[{type:'text',text:e.passage+'\nSource: '+e.topic_id+' | '+e.section_id+' | source '+e.source_revision.slice(0,12)}]};
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
 let calls=0;
 const client={callTool:async({name,arguments:args})=>{
  if(name==='mql5_chm_read_image')return {structuredContent:{sha256:manifest.cases.find(c=>c.id==='focus-button').expected.image.sha256,primary_topic_citation:{section_id:fault==='image-citation'?'wrong':manifest.cases.find(c=>c.id==='focus-button').expected.section_id}},content:[{type:'image',data:Buffer.from('changed bytes').toString('base64')}]};
  const c=manifest.cases.find(c=>JSON.stringify(c.arguments)===JSON.stringify(args));
  if(!c)return {structuredContent:{images:fault==='following-section'?[{asset_id:manifest.cases.find(c=>c.id==='focus-button').expected.image.asset_id}]:[]},content:[]};
  const r=response(c);if(fault==='sample-revision'&&calls++===2)r.structuredContent.index_sha256='0'.repeat(64);return r;
 }};
 const result=await measureQuality(client,manifest);assert.equal(result.status,'failed');assert.equal(result.cases.length,32);assert.ok(result.cases.every(c=>c.warm_samples_ms.length===9));
 assert.ok(result.cases.some(c=>c.issues.some(issue=>issue.includes(fault==='following-section'?'following section':fault==='sample-revision'?'identity mismatch':'image bytes or citation'))));
});

test('quality retains all failed cases when protocol calls throw',async()=>{const result=await measureQuality({callTool:async()=>{throw new Error('malformed protocol response')}},manifest);assert.equal(result.status,'failed');assert.equal(result.cases.length,32);assert.ok(result.cases.every(c=>c.initial_response.protocol_error==='malformed protocol response'&&c.status==='failed'));});
