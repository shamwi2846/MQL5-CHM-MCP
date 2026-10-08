// Supplement older compatibility harnesses without changing the approved peer.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFile,readdir,writeFile,rm,realpath} from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';

const [mcp,skill,output]=process.argv.slice(2);
for (const value of [mcp,skill,output]) assert.ok(value && path.isAbsolute(value),'Select absolute evidence paths');
const {buildFixture}=await import(pathToFileURL(path.join(mcp,'tests/helpers/runtime-fixture.mjs')));
const {Client}=await import(pathToFileURL(path.join(mcp,'node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')));
const {StdioClientTransport}=await import(pathToFileURL(path.join(mcp,'node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
async function inventory(root){
  const files={};
  async function visit(directory){
    for(const item of await readdir(directory,{withFileTypes:true})){
      assert.equal(item.isSymbolicLink(),false,'Unexpected linked evidence');
      const file=path.join(directory,item.name);
      if(item.isDirectory())await visit(file);
      else if(item.isFile())files[path.relative(root,file).replaceAll('\\','/')]=sha(await readFile(file));
    }
  }
  await visit(root);return Object.fromEntries(Object.entries(files).sort());
}
const commit=root=>execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
const fixture=await buildFixture({compatibilityTopics:true});
const server=path.join(mcp,'build/candidate-v12/app/server.mjs');
const client=new Client({name:'approved-peer-evidence',version:'1.0.0'});
const bootstrap=`import {main} from ${JSON.stringify(pathToFileURL(server).href)};await main({root:${JSON.stringify(fixture.root)}});`;
const transport=new StdioClientTransport({command:process.execPath,args:['--input-type=module','--eval',bootstrap],cwd:fixture.root,stderr:'pipe'});
transport.stderr?.on('data',()=>{});
try{
  const artifacts=await inventory(fixture.root),skillFiles=await inventory(skill),serverHash=sha(await readFile(server));
  await client.connect(transport);
  const tools=(await client.listTools()).tools.map(t=>t.name).sort();assert.equal(tools.length,5);
  const response=await client.callTool({name:'mql5_chm_status',arguments:{}});assert.notEqual(response.isError,true);
  const status=response.structuredContent;assert.equal(status.index_revision,status.index_sha256);assert.match(status.index_revision,/^[0-9a-f]{64}$/u);
  const version=JSON.parse(await readFile(path.join(mcp,'package.json'),'utf8')).version;
  assert.equal(client.getServerVersion().version,version);
  assert.deepEqual(await inventory(fixture.root),artifacts);assert.deepEqual(await inventory(skill),skillFiles);assert.equal(sha(await readFile(server)),serverHash);
  const result={schema_version:1,status:'passed',mode:'synthetic_corpus',mcp_checkout_commit:commit(mcp),skill_checkout_commit:commit(skill),server_version:version,skill_version:JSON.parse(await readFile(path.join(skill,'version.json'),'utf8')).version,server_sha256:serverHash,skill_files_sha256:skillFiles,corpus_revision:status.corpus_revision,index_revision:status.index_revision,artifact_sha256:artifacts,tools};
  await writeFile(output,JSON.stringify(result,null,2)+'\n',{flag:'wx'});console.log('PEER_EVIDENCE_PASS');
}finally{
  await client.close();
  const owned=await realpath(fixture.root),parent=(await realpath(tmpdir()))+path.sep;
  assert.ok(owned.toLowerCase().startsWith(parent.toLowerCase())&&path.basename(owned).startsWith('mql5-chm-v12-runtime-'),'Unexpected fixture cleanup path');
  await rm(owned,{recursive:true,force:true});
}
