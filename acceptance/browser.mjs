import assert from 'node:assert/strict';
import {mkdtemp,mkdir,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
const launcher=process.env.TEST_LAUNCH_URL, worker='http://127.0.0.1:7381';
const token=process.env.WORKBENCH_HOST_TOKEN;
const call=(path, body)=>fetch(worker+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,
  'Content-Type':'application/json','X-Workbench-Kind':'owner','X-Workbench-Session':'library-browser'},body:body?JSON.stringify(body):undefined});
const browser=await chromium.launch({headless:true});
try {
  for(const width of [1440,390]){
    const id='browser-library-'+width+'-'+Date.now();
    const name='挂载外部资料 '+width;
    const root=await mkdtemp(join(tmpdir(),'wb-standard-browser-'));
    const folder=join(root,'验收语料-'+width);
    await mkdir(folder);
    await writeFile(join(folder,'说明.md'),'# 导入标记 '+width+'\n\n![[地图.canvas]]');
    await writeFile(join(folder,'地图.canvas'),'{}');
    assert.equal((await call('/resources',{id,name,kind:'database',sections:[{id:'content',name:'内容',fields:['value']}]})).status,200);
    const page=await browser.newPage({viewport:{width,height:900},isMobile:width===390,hasTouch:width===390,acceptDownloads:true});
    const errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto(launcher);
    if(width===390){
      const open=page.getByRole('button',{name:'打开侧边栏',exact:true});
      if(await open.isVisible())await open.click();
    }
    const knowledge=page.getByRole('button',{name:'知识库',exact:true});
    if(!await knowledge.isVisible())await page.getByRole('button',{name:'更多',exact:true}).click();
    await knowledge.click();
    await page.getByRole('heading',{name:'知识库',exact:true}).waitFor();
    const del=page.getByRole('button',{name:'删除 '+name,exact:true});
    await del.waitFor();
    const buttons=del.locator('..').getByRole('button');
    assert.deepEqual(await buttons.allTextContents(),['权限设置','编辑','删除']);
    const row=del.locator('../..');
    assert.equal(await row.evaluate(e=>e.scrollWidth<=e.clientWidth+1),true);
    await del.click();
    await page.getByRole('button',{name:'取消',exact:true}).click();
    assert.equal((await call('/resources').then(r=>r.json())).some(r=>r.id===id),true);
    await del.click();
    await page.screenshot({path:fileURLToPath(new URL('./database-'+width+'.png',import.meta.url))});
    await page.getByRole('button',{name:'确认删除',exact:true}).click();
    await del.waitFor({state:'detached'});
    assert.equal((await call('/resources').then(r=>r.json())).some(r=>r.id===id),false);
    await page.getByRole('button',{name:'语料库',exact:true}).click();
    await page.getByRole('button',{name:'导入本地文件夹',exact:true}).click();
    await page.locator('input[type=file][webkitdirectory]').setInputFiles(folder);
    await page.getByRole('button',{name:'导入语料库',exact:true}).click();
    await page.getByRole('button',{name:'返回语料',exact:true}).waitFor();
    const rowData=(await call('/resources').then(r=>r.json())).find(r=>r.name==='验收语料-'+width);
    assert.ok(rowData?.currentVersion);
    const download=page.waitForEvent('download');
    await page.getByRole('link',{name:'下载语料库 ZIP',exact:true}).click();
    await (await download).saveAs(fileURLToPath(new URL('./export-'+width+'.zip',import.meta.url)));
    await page.getByRole('button',{name:'返回语料',exact:true}).click();
    await page.getByRole('button',{name:'删除 验收语料-'+width,exact:true}).click();
    await page.getByRole('button',{name:'确认删除',exact:true}).click();
    await page.getByRole('button',{name:'删除 验收语料-'+width,exact:true}).waitFor({state:'detached'});
    assert.equal((await call('/resources').then(r=>r.json())).some(r=>r.id===rowData.id),false);
    const cross=await page.request.post(new URL('/workbench-api/resource-delete',page.url()).href,{headers:{origin:'https://other.invalid'},data:{resourceId:rowData.id,revision:rowData.revision}});
    assert.equal(cross.status(),403);
    assert.equal(await readFile(join(folder,'地图.canvas'),'utf8'),'{}');
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({width,databaseCancel:true,databaseDelete:true,folderImport:true,archiveExport:true,corpusDelete:true,sourcePreserved:true}));
    await page.close();
  }
} finally {await browser.close();}
