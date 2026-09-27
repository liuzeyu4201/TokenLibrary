import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
async function load(page, text='') {
  await page.goto('/');
  await page.waitForFunction(() => window.tlEditorReady);
  await page.evaluate(value => window.tlSetMarkdown(value),text);
}
test('opening and switching modes preserves exact Markdown without autosave',async ({page})=>{
  await load(page);
  const text='# 研究\n\n`foo ${bar}` 和 **粗体**\n\n| 项 | 值 |\n|---|---|\n|甲|1|\n\n- [x] 完成\n\n$$\n\\frac{a}{b}\n$$\n';
  await page.evaluate(text=>{window.changes=[];window.addEventListener('tl-change',event=>window.changes.push(event.detail));window.tlSetMarkdown(text);},text);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview table')).toBeVisible();
  await expect(page.locator('#preview .katex')).toBeVisible();
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await expect(page.getByRole('textbox',{name:'Markdown 源码'})).toHaveValue(text);
  await page.getByRole('button',{name:'排版',exact:true}).click();
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(text);
  expect(await page.evaluate(()=>window.changes)).toEqual([]);
});
test('rich editing saves rendered text, supports undo, and retains source on mode switch',async ({page})=>{
  await load(page,'# 研究笔记\n\n原文\n');
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});
  await editor.click();await page.keyboard.press('ControlOrMeta+End');await page.keyboard.type(' appended');
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toContain('appended');
  await page.keyboard.press('ControlOrMeta+z');
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).not.toContain('appended');
  await page.keyboard.type(' appended');
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toContain('appended');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  expect(await page.getByRole('textbox',{name:'Markdown 源码'}).inputValue()).toContain('appended');
});
test('offline Mermaid and math render; bad syntax exposes source and error',async ({page})=>{
  await load(page,'```mermaid\nflowchart LR\nA[论文] --> B[笔记]\n```\n\n$x^2$\n');
  await page.context().setOffline(true);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview .diagram svg')).toBeVisible();
  await expect(page.locator('#preview .diagram svg')).toContainText('论文');
  await expect(page.locator('#preview .diagram svg')).toContainText('笔记');
  expect(await page.locator('#preview .diagram foreignObject').count()).toBe(0);
  await expect(page.locator('#preview .katex')).toBeVisible();
  await page.evaluate(()=>window.tlSetMarkdown('```mermaid\nflowchart LR\nA[broken\n```\n\n$\\invalidCommand{x}$'));
  await expect(page.locator('#preview')).toContainText('流程图错误');
  await expect(page.locator('#preview')).toContainText('公式错误');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('A[broken');
});
test('rich Mermaid finishes offline for the native import fixture without changing Markdown',async ({page})=>{
  const text=readFileSync(new URL('./fixtures/offline-mermaid-latex.md',import.meta.url),'utf8');
  await load(page);
  await page.context().setOffline(true);
  await page.evaluate(value=>{
    window.changes=[];window.addEventListener('tl-change',event=>window.changes.push(event.detail));
    window.tlSetMarkdown(value);
  },text);
  const diagram=page.locator('#rich .preview-panel .diagram svg');
  await expect(diagram).toBeVisible();
  for (const label of ['书籍','论文','研究笔记','个人档案']) await expect(diagram).toContainText(label);
  await expect(page.locator('#rich [data-tl-diagram-request]')).toHaveCount(0);
  expect(await page.locator('#rich .preview-panel foreignObject').count()).toBe(0);
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(text);
  expect(await page.evaluate(()=>window.changes)).toEqual([]);
});
test('rich Mermaid syntax failure can recover without changing other code blocks',async ({page})=>{
  await load(page,'```mermaid\nflowchart LR\nA[broken\n```\n\n```javascript\nconst untouched = 1;\n```\n');
  await expect(page.locator('#rich .preview-panel .render-error')).toContainText('流程图错误');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('A[broken');
  await page.evaluate(()=>window.tlSetMarkdown('```mermaid\nflowchart LR\nA[恢复] --> B[完成]\n```\n\n```javascript\nconst untouched = 1;\n```\n'));
  await expect(page.locator('#rich .preview-panel svg')).toContainText('恢复');
  await expect(page.locator('#rich .preview-panel svg')).toContainText('完成');
  await expect(page.locator('#rich .preview-panel')).toHaveCount(1);
  await expect(page.locator('#rich .render-error')).toHaveCount(0);
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('const untouched = 1;');
});
test('late rich Mermaid results cannot resurrect a removed preview',async ({page})=>{
  await load(page,'# Before\n');
  await page.evaluate(()=>{
    window.realAnimationFrame=window.requestAnimationFrame;
    window.delayedFrames=[];
    window.requestAnimationFrame=callback=>{window.delayedFrames.push(callback);return 0;};
    window.tlSetMarkdown('```mermaid\nflowchart LR\nA[旧图] --> B[不得返回]\n```\n');
  });
  await expect(page.locator('#rich [data-tl-diagram-request]')).toContainText('正在绘制');
  // Hold animation-frame completion while the same code block changes language.
  await page.waitForTimeout(250);
  expect(await page.evaluate(()=>window.delayedFrames.length)).toBeGreaterThan(0);
  await page.evaluate(()=>window.tlSetMarkdown('```javascript\nconst newer = "current";\n```\n'));
  await expect(page.locator('#rich .preview-panel')).toHaveCount(0);
  await page.evaluate(()=>{
    window.requestAnimationFrame=window.realAnimationFrame;
    for (const callback of window.delayedFrames.splice(0)) callback(performance.now());
  });
  await page.waitForTimeout(250);
  await expect(page.locator('#rich .preview-panel')).toHaveCount(0);
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe('```javascript\nconst newer = "current";\n```\n');
  await page.evaluate(()=>window.tlSetMarkdown('```mermaid\nflowchart LR\nA[新图] --> B[正常]\n```\n'));
  await expect(page.locator('#rich .preview-panel svg')).toContainText('新图');
  await expect(page.locator('#rich .preview-panel svg')).not.toContainText('旧图');
});
test('source entry does not execute HTML, scripts, interpolation, or unsafe URLs',async ({page})=>{
  await load(page,'<img src=x onerror="window.evil=1"><script>window.evil=2</script>\n\n[bad](javascript:alert(1))\n\n`${window.evil=3}`');
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  expect(await page.evaluate(()=>window.evil)).toBeUndefined();
  expect(await page.locator('#preview script').count()).toBe(0);
  expect(await page.locator('#preview [onerror]').count()).toBe(0);
  expect(await page.locator('#preview a[href^="javascript:"]').count()).toBe(0);
});
test('legacy voice and image block Markdown is preserved and playable',async ({page})=>{
  const text='<!--tl:voice id="v" duration="1.5"-->\n[voice](media/demo.m4a)\ncaption\n<!--/tl:voice-->';
  await load(page,text);
  await expect(page.getByRole('textbox',{name:'Markdown 源码'})).toHaveValue(text);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview audio')).toHaveAttribute('controls','');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(text);
});
test('image upload embeds persistent data in browser fixture and survives reopening',async ({page})=>{
  await load(page,'');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await page.locator('#image-file').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toContain('data:image/png;base64,');
  const text=await page.evaluate(()=>window.tlGetMarkdown());
  await load(page,text);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview img')).toBeVisible();
});
test('mobile and dark mode controls remain usable without horizontal overflow',async ({page})=>{
  await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});
  await load(page,'# 论文笔记\n\n中文输入与阅读。\n');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await page.getByRole('textbox',{name:'Markdown 源码'}).fill('# 手机笔记\n\n离线内容');
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview')).toContainText('离线内容');
  expect(await page.evaluate(()=>document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({path:'test-results/mobile-dark.png',fullPage:true});
});
test('archived notes open in reading mode and resume the same Markdown after explicit edit',async({page})=>{
  const text='# 已归档\n\n长期保留的研究笔记。\n\n$x^2$\n';
  await load(page,text);
  await page.evaluate(()=>window.tlSetReadOnly(true));
  await expect(page.locator('#preview')).toContainText('长期保留');
  await expect(page.getByRole('button',{name:'排版',exact:true})).toBeDisabled();
  await expect(page.getByRole('button',{name:'源码',exact:true})).toBeDisabled();
  await page.evaluate(()=>{window.tlSetPreview(false);window.tlFind('长期保留');});
  await expect(page.locator('#preview')).toBeVisible();
  await expect(page.locator('#source')).toBeHidden();
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(text);
  await page.evaluate(()=>window.tlSetReadOnly(false));
  await expect(page.getByRole('textbox',{name:'笔记正文',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await expect(page.locator('#source')).toHaveValue(text);
});
test('archiving during rich input collects the last transaction before switching to read mode',async({page})=>{
  await load(page,'# Draft\n\n');
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});
  await editor.click();await page.keyboard.press('ControlOrMeta+End');await page.keyboard.type('last archived input');
  await page.evaluate(()=>window.tlSetReadOnly(true));
  await expect(page.locator('#preview')).toContainText('last archived input');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('last archived input');
});
test('immediate mode switch flushes the final rich transaction',async ({page})=>{
  await load(page,'# draft\n\n');
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  await page.keyboard.press('ControlOrMeta+End');
  await page.keyboard.type('last keystrokes');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  expect(await page.getByRole('textbox',{name:'Markdown 源码'}).inputValue()).toContain('last keystrokes');
});
test('failed local save retains text against host refresh and offers retry',async ({page})=>{
  await load(page,'old');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await page.getByRole('textbox',{name:'Markdown 源码'}).fill('unsaved work');
  await page.evaluate(()=>window.tlSaved(false,'磁盘已满'));
  await expect(page.getByRole('button',{name:'重试保存'})).toBeVisible();
  expect(await page.evaluate(()=>window.tlAcceptUpdate('old','unsaved work'))).toBe(false);
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe('unsaved work');
  await page.getByRole('button',{name:'重试保存'}).click();
  await page.evaluate(()=>window.tlSaved(true));
  await expect(page.getByRole('button',{name:'重试保存'})).toBeHidden();
  await expect(page.locator('#status')).toHaveText('已保存到本机');
});

async function nativeLoad(page,text) {
  await page.addInitScript(()=>{
    window.nativeSaves=[];window.nativeUploads=[];window.nativeLinks=[];
    window.webkit={messageHandlers:{
      tlSave:{postMessage:value=>window.nativeSaves.push(value)},
      tlReady:{postMessage:()=>{}},tlAttachment:{postMessage:value=>window.nativeUploads.push(value)},
      tlOpenLink:{postMessage:value=>window.nativeLinks.push(value)},
    }};
  });
  await load(page,text);
  await page.getByRole('button',{name:'源码',exact:true}).click();
}
for (const entry of ['clean refresh','canonical save']) {
  test(`source caret stays in its paragraph across ${entry} while native typing continues`,async({page})=>{
    const base='Remote: base\n\nLocal: baseabcd\n\nTail: keep\n';
    await nativeLoad(page,base);
    const source=page.getByRole('textbox',{name:'Markdown 源码'});
    await source.evaluate(element=>{element.focus();const at=element.value.indexOf('abcd')+4;element.setSelectionRange(at,at);});
    await page.keyboard.type('e');
    const submitted=await page.evaluate(()=>window.nativeSaves.at(-1));
    const canonical=submitted.proposedMarkdown.replace('Remote: base','Remote: REMOTE-ccf40091a386');
    if(entry==='clean refresh') {
      await page.evaluate(save=>window.tlSaveResult(save.requestId,true,save.proposedMarkdown),submitted);
      expect(await page.evaluate(value=>window.tlAcceptUpdate(value),canonical)).toBe(true);
    } else await page.evaluate(({save,value})=>window.tlSaveResult(save.requestId,true,value),{save:submitted,value:canonical});
    await page.keyboard.type('fghXYZ ');await page.keyboard.press('Enter');
    expect(await source.inputValue()).toBe(canonical.replace('Local: baseabcde','Local: baseabcdefghXYZ \n'));
    expect(await source.evaluate(element=>document.activeElement===element)).toBe(true);
  });
}
test('source selection maps independent edits before and after it and keeps its backward direction',async({page})=>{
  const base='Remote: one\n\nLocal: 研究🧪 selected text\n\nTail: old\n';
  await nativeLoad(page,base);
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.evaluate(element=>{element.focus();const at=element.value.indexOf('selected');element.setSelectionRange(at,at+8,'backward');});
  const changed=base.replace('Remote: one','Remote: substantially longer').replace('Tail: old','Tail: new version');
  expect(await page.evaluate(value=>window.tlAcceptUpdate(value),changed)).toBe(true);
  const selection=await source.evaluate(element=>({text:element.value.slice(element.selectionStart,element.selectionEnd),direction:element.selectionDirection}));
  expect(selection).toEqual({text:'selected',direction:'backward'});
  await page.keyboard.type('replacement');
  expect(await source.inputValue()).toBe(changed.replace('selected','replacement'));
});
test('source caret also maps separate changes on the same line without consuming unchanged text',async({page})=>{
  await nativeLoad(page,'aaa KEEP zzz\n');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.evaluate(element=>{element.focus();element.setSelectionRange(8,8);});
  expect(await page.evaluate(()=>window.tlAcceptUpdate('aaaaaaaa KEEP ZZZ\n'))).toBe(true);
  expect(await source.evaluate(element=>element.selectionStart)).toBe(13);
  await page.keyboard.type('XYZ');
  expect(await source.inputValue()).toBe('aaaaaaaa KEEPXYZ ZZZ\n');
});
test('source caret and viewport stay stable for updates below the selection and unchanged acknowledgements',async({page})=>{
  await page.setViewportSize({width:390,height:600});
  const base=Array.from({length:150},(_,index)=>`Line ${index}: text`).join('\n')+'\n';
  await nativeLoad(page,base);
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  const previous=await source.evaluate(element=>{element.focus();const at=element.value.indexOf('Line 75:')+8;element.setSelectionRange(at,at);element.scrollTop=1000;return {start:element.selectionStart,top:element.scrollTop};});
  const changed=base.replace('Line 140: text','Line 140: remote changes here');
  expect(await page.evaluate(value=>window.tlAcceptUpdate(value),changed)).toBe(true);
  expect(await source.evaluate(element=>({start:element.selectionStart,top:element.scrollTop}))).toEqual(previous);
  await page.keyboard.type('X');
  const save=await page.evaluate(()=>window.nativeSaves.at(-1));
  const caret=await source.evaluate(element=>element.selectionStart);
  await page.evaluate(value=>window.tlSaveResult(value.requestId,true,value.proposedMarkdown),save);
  expect(await source.evaluate(element=>element.selectionStart)).toBe(caret);
  expect(await source.inputValue()).toBe(changed.replace('Line 75: text','Line 75:X text'));
});
test('source caret maps large notes with separate remote edits and a preceding deletion',async({page})=>{
  const base=Array.from({length:1200},(_,index)=>`Line ${index}: text`).join('\n')+'\n';
  await nativeLoad(page,base);
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.evaluate(element=>{element.focus();const at=element.value.indexOf('Line 650: text')+14;element.setSelectionRange(at,at);});
  const changed=base.replace('Line 0: text\n','').replace('Line 1199: text','Line 1199: remotely extended');
  expect(await page.evaluate(value=>window.tlAcceptUpdate(value),changed)).toBe(true);
  await page.keyboard.type('XYZ ');
  expect(await source.inputValue()).toBe(changed.replace('Line 650: text','Line 650: textXYZ '));
});
test('an idle rich peer never rewrites source spaces and trailing newlines received from sync',async({page,context})=>{
  const peer=await context.newPage();
  await nativeLoad(page,'# note\n\n');await nativeLoad(peer,'# note\n\n');
  await peer.getByRole('button',{name:'排版',exact:true}).click();
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.focus();await source.press('ControlOrMeta+End');
  let expected='# note\n\n';
  for (const key of ['h','e','l','l','o','Space','w','o','r','l','d','Enter','Enter']) {
    await source.press(key);
    expected+=key==='Space'?' ':key==='Enter'?'\n':key;
    const proposal=await page.evaluate(()=>window.nativeSaves.at(-1));
    expect(proposal.proposedMarkdown).toBe(expected);
    expect(await peer.evaluate(text=>window.tlAcceptUpdate(text),expected)).toBe(true);
    await page.evaluate(save=>window.tlSaveResult(save.requestId,true,save.proposedMarkdown),proposal);
    await peer.waitForTimeout(225); // Milkdown's listener itself is debounced by 200 ms.
    expect(await peer.evaluate(()=>window.nativeSaves)).toEqual([]);
    expect(await peer.evaluate(()=>window.tlGetMarkdown())).toBe(expected);
    await expect(source).toHaveValue(expected);
  }
  await peer.close();
});

test('source composition is not replaced by a clean remote refresh after an intermediate save acknowledgement',async({page})=>{
  await nativeLoad(page,'start ');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.focus();
  await source.evaluate(element=>{
    element.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true,data:''}));
    element.value='start zhong';element.setSelectionRange(element.value.length,element.value.length);
    const property=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value');
    window.sourceAssignments=0;
    Object.defineProperty(element,'value',{configurable:true,get(){return property.get.call(this);},set(value){window.sourceAssignments++;property.set.call(this,value);}});
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',data:'zhong',isComposing:true}));
  });
  expect(await page.evaluate(()=>window.nativeSaves)).toEqual([]);
  await page.evaluate(()=>{const save=window.nativeSaves.at(-1);if(save)window.tlSaveResult(save.requestId,true,save.proposedMarkdown);});
  expect(await page.evaluate(()=>window.tlAcceptUpdate('REMOTE start zhong'))).toBe(false);
  await expect(source).toHaveValue('start zhong');
  expect(await page.evaluate(()=>window.sourceAssignments)).toBe(0);
  await source.evaluate(element=>{
    element.value='start 中文 ';element.setSelectionRange(element.value.length,element.value.length);
    element.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'中文 '}));
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'中文 '}));
  });
  const submitted=await page.evaluate(()=>window.nativeSaves.at(-1));
  expect(submitted.proposedMarkdown).toBe('start 中文 ');
  await page.evaluate(save=>window.tlSaveResult(save.requestId,true,save.proposedMarkdown),submitted);
  await expect(source).toHaveValue('start 中文 ');
});

test('an older save acknowledgement during source composition cannot replace the candidate or its merge base',async({page})=>{
  await nativeLoad(page,'alpha\nbeta');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.fill('LOCAL alpha\nbeta');
  await source.evaluate(element=>{
    element.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
    element.value='LOCAL alpha zhong\nbeta';
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',isComposing:true}));
  });
  expect(await page.evaluate(()=>window.tlAcceptUpdate('alpha\nREMOTE beta'))).toBe(false);
  await page.evaluate(()=>window.tlSaveResult(1,true,'LOCAL alpha\nREMOTE beta'));
  await expect(source).toHaveValue('LOCAL alpha zhong\nbeta');
  expect(await page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  await source.evaluate(element=>{
    element.value='LOCAL alpha 中文 \nbeta';
    element.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'中文 '}));
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));
  });
  const last=await page.evaluate(()=>window.nativeSaves.at(-1));
  expect(last.baseMarkdown).toBe('LOCAL alpha\nbeta');
  expect(last.proposedMarkdown).toBe('LOCAL alpha 中文 \nbeta');
  await page.evaluate(id=>window.tlSaveResult(id,true,'LOCAL alpha 中文 \nREMOTE beta'),last.requestId);
  await expect(source).toHaveValue('LOCAL alpha 中文 \nREMOTE beta');
  expect((await page.evaluate(()=>window.tlFlushEdit())).saved).toBe(true);
});

test('cancelling a source candidate applies the deferred host update without saving marked text',async({page})=>{
  await nativeLoad(page,'base');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.evaluate(element=>{
    element.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
    element.value='base zhong';
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',isComposing:true}));
  });
  expect(await page.evaluate(()=>window.tlAcceptUpdate('REMOTE base'))).toBe(false);
  expect((await page.evaluate(()=>window.tlFlushEdit())).saved).toBe(false);
  await expect(source).toHaveValue('base zhong');
  await source.evaluate(element=>{
    element.value='base';element.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:''}));
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteCompositionText'}));
  });
  await expect(source).toHaveValue('REMOTE base');
  expect(await page.evaluate(()=>window.nativeSaves)).toEqual([]);
  expect(await page.evaluate(()=>window.tlAcceptUpdate('LATEST base'))).toBe(true);
  await expect(source).toHaveValue('LATEST base');
  expect((await page.evaluate(()=>window.tlFlushEdit())).saved).toBe(true);
});
test('native autosave serializes rapid edits and keeps their actual base after a remote merge',async({page})=>{
  await nativeLoad(page,'alpha\nbeta');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.fill('LOCAL alpha\nbeta');
  await source.fill('LOCAL alpha plus\nbeta');
  expect(await page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  expect(await page.evaluate(()=>window.tlAcceptUpdate('alpha\nREMOTE beta'))).toBe(false);
  await page.evaluate(()=>window.tlSaveResult(1,true,'LOCAL alpha\nREMOTE beta'));
  const saves=await page.evaluate(()=>window.nativeSaves);
  expect(saves[0].baseMarkdown).toBe('alpha\nbeta');
  expect(saves[1].baseMarkdown).toBe('LOCAL alpha\nbeta');
  expect(saves[1].proposedMarkdown).toBe('LOCAL alpha plus\nbeta');
  await page.evaluate(()=>window.tlSaveResult(2,true,'LOCAL alpha plus\nREMOTE beta'));
  await expect(source).toHaveValue('LOCAL alpha plus\nREMOTE beta');
  expect(await page.evaluate(()=>window.nativeSaves.length)).toBe(2);
});
test('remote refresh during rich typing preserves the old edit base for native merge',async({page})=>{
  await nativeLoad(page,'alpha\n\nbeta\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  await page.keyboard.press('ControlOrMeta+End');await page.keyboard.type(' LOCAL');
  expect(await page.evaluate(()=>window.tlAcceptUpdate('REMOTE alpha\n\nbeta\n'))).toBe(false);
  const saves=await page.evaluate(()=>window.nativeSaves);
  expect(saves[0].baseMarkdown).toBe('alpha\n\nbeta\n');
  expect(saves[0].proposedMarkdown).toContain('LOCAL');
  await page.evaluate(()=>window.tlSaveResult(1,true,'REMOTE alpha\n\nbeta LOCAL\n'));
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('REMOTE alpha');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('LOCAL');
});
for(const entry of ['clean refresh','canonical save']) {
  test(`rich caret stays in the active paragraph across ${entry} and subsequent typing`,async({page})=>{
    await nativeLoad(page,'Remote: base\n\nLocal: baseabcd\n\nTail: keep\n');
    await page.getByRole('button',{name:'排版',exact:true}).click();
    const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});await editor.focus();
    await editor.locator('p').nth(1).evaluate(paragraph=>{
      const range=document.createRange();range.selectNodeContents(paragraph);range.collapse(false);
      const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
      document.dispatchEvent(new Event('selectionchange'));
    });
    await page.keyboard.type('e');
    await expect.poll(()=>page.evaluate(()=>window.nativeSaves.length)).toBe(1);
    const save=await page.evaluate(()=>window.nativeSaves[0]);
    const changed=save.proposedMarkdown.replace('Remote: base','Remote: remote longer').replace('Tail: keep','Tail: changed independently');
    if(entry==='clean refresh') {
      await page.evaluate(value=>window.tlSaveResult(value.requestId,true,value.proposedMarkdown),save);
      expect(await page.evaluate(value=>window.tlAcceptUpdate(value),changed)).toBe(true);
    } else await page.evaluate(({save,changed})=>window.tlSaveResult(save.requestId,true,changed),{save,changed});
    await page.keyboard.type('fghXYZ');
    expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(changed.replace('Local: baseabcde','Local: baseabcdefghXYZ'));
    expect(await editor.evaluate(element=>element.contains(document.activeElement))).toBe(true);
  });
}
test('rich selection survives inserted blocks and nested list changes on both sides',async({page})=>{
  await nativeLoad(page,'Remote: base\n\n- first\n- Local: base\n- last\n\nTail: keep\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});await editor.focus();
  await editor.locator('li p').nth(1).evaluate(paragraph=>{
    const range=document.createRange();range.selectNodeContents(paragraph);range.collapse(false);
    const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
  });
  const changed='New paragraph before\n\nRemote: expanded\n\n- inserted first\n- first expanded\n- Local: base\n- last expanded\n\nTail: separately changed\n';
  expect(await page.evaluate(value=>window.tlAcceptUpdate(value),changed)).toBe(true);
  await page.keyboard.type('XYZ');
  await expect(editor.locator('li p').filter({hasText:'Local:'})).toHaveText('Local: baseXYZ');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('last expanded');
  await expect(page.locator('#error')).not.toBeVisible();
});
test('rich selection preserves an intact word between two same-line remote edits',async({page})=>{
  await nativeLoad(page,'aaa KEEP zzz\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});await editor.focus();
  await editor.locator('p').evaluate(paragraph=>{
    const selection=window.getSelection();selection.setBaseAndExtent(paragraph.firstChild,8,paragraph.firstChild,4);
    document.dispatchEvent(new Event('selectionchange'));
  });
  expect(await page.evaluate(()=>window.tlAcceptUpdate('aaaaaaaa KEEP ZZZ\n'))).toBe(true);
  expect(await page.evaluate(()=>window.getSelection().toString())).toBe('KEEP');
  expect(await page.evaluate(()=>window.getSelection().anchorOffset>window.getSelection().focusOffset)).toBe(true);
  await page.keyboard.type('typed');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe('aaaaaaaa typed ZZZ\n');
});
test('rich caret survives remote formatting that splits an unchanged text node',async({page})=>{
  await nativeLoad(page,'aaa KEEP zzz\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});await editor.focus();
  await editor.locator('p').evaluate(paragraph=>{
    const selection=window.getSelection();selection.setBaseAndExtent(paragraph.firstChild,8,paragraph.firstChild,8);
    document.dispatchEvent(new Event('selectionchange'));
  });
  expect(await page.evaluate(()=>window.tlAcceptUpdate('**aaa** KEEP zzz\n'))).toBe(true);
  await page.keyboard.type('XYZ');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe('**aaa** KEEPXYZ zzz\n');
});
test('undoing local rich typing does not undo independent remote changes',async({page})=>{
  await nativeLoad(page,'Remote: base\n\nLocal: base\n\nTail: keep\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  const editor=page.getByRole('textbox',{name:'笔记正文',exact:true});await editor.focus();
  await editor.locator('p').nth(1).evaluate(paragraph=>{
    const range=document.createRange();range.selectNodeContents(paragraph);range.collapse(false);
    const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
  });
  await page.keyboard.type(' typed');
  await expect.poll(()=>page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  const save=await page.evaluate(()=>window.nativeSaves[0]);
  await page.evaluate(save=>window.tlSaveResult(save.requestId,true,save.proposedMarkdown.replace('Remote: base','Remote: remote').replace('Tail: keep','Tail: changed')),save);
  await page.keyboard.press('ControlOrMeta+z');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe('Remote: remote\n\nLocal: base\n\nTail: changed\n');
});
test('updating a hidden rich editor never steals the source caret or keyboard focus',async({page})=>{
  await nativeLoad(page,'Remote: base\n\nLocal: base\n\nTail: keep\n');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.evaluate(element=>{element.focus();const at=element.value.indexOf('Local: base')+11;element.setSelectionRange(at,at);});
  expect(await page.evaluate(()=>window.tlAcceptUpdate('Remote: remotely changed\n\nLocal: base\n\nTail: separately changed\n'))).toBe(true);
  await expect(source).toBeFocused();await page.keyboard.type('XYZ');
  expect(await source.inputValue()).toBe('Remote: remotely changed\n\nLocal: baseXYZ\n\nTail: separately changed\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toContain('Local: baseXYZ');
});
test('conflicting native save keeps editable draft against later refreshes',async({page})=>{
  await nativeLoad(page,'before');
  await page.getByRole('textbox',{name:'Markdown 源码'}).fill('local draft');
  await page.evaluate(()=>window.tlSaveResult(1,false,'remote draft','恢复草稿已保存'));
  expect(await page.evaluate(()=>window.tlAcceptUpdate('remote draft'))).toBe(false);
  await expect(page.getByRole('textbox',{name:'Markdown 源码'})).toHaveValue('local draft');
  await expect(page.locator('#error')).toContainText('恢复草稿已保存');
  await page.getByRole('textbox',{name:'Markdown 源码'}).fill('local draft continued');
  expect(await page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  await page.getByRole('button',{name:'重试保存'}).click();
  const latest=await page.evaluate(()=>window.nativeSaves.at(-1));
  expect(latest.baseMarkdown).toBe('before');expect(latest.proposedMarkdown).toBe('local draft continued');
});
test('native image bridge saves a portable relative path and renders the local asset scheme',async({page})=>{
  await nativeLoad(page,'');
  await page.locator('#image-file').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  await expect.poll(()=>page.evaluate(()=>window.nativeUploads.length)).toBe(1);
  await page.evaluate(()=>window.tlAttachmentResult(window.nativeUploads[0].id,'media/test.png',null));
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toContain('](media/test.png)');
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview img')).toHaveAttribute('src','library-asset://local/media/test.png');
});
test('rich native image import inserts a block and persists it before closing',async({page})=>{
  await nativeLoad(page,'Before image\n');
  await page.getByRole('button',{name:'排版',exact:true}).click();
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  await page.keyboard.press('ControlOrMeta+End');
  await page.locator('#image-file').setInputFiles({name:'pixel[1].png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  await expect.poll(()=>page.evaluate(()=>window.nativeUploads.length)).toBe(1);
  await page.evaluate(()=>{window.closePayload=null;window.tlFlushEdit().then(value=>window.closePayload=value);});
  await page.evaluate(()=>window.tlAttachmentResult(window.nativeUploads[0].id,'media/rich.png',null));
  await expect(page.locator('#rich img[data-type="image-block"]')).toHaveAttribute('src','library-asset://local/media/rich.png');
  await expect(page.locator('#rich img[data-type="image-block"]')).toHaveAttribute('alt','pixel[1].png');
  await expect.poll(()=>page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  const proposal=await page.evaluate(()=>window.nativeSaves[0]);
  expect(proposal.baseMarkdown).toBe('Before image\n');
  expect(proposal.proposedMarkdown).toContain('Before image');
  expect(proposal.proposedMarkdown).toContain('](media/rich.png)');
  expect(proposal.proposedMarkdown).toContain('![pixel\\[1\\].png]');
  expect(proposal.proposedMarkdown).not.toContain('library-asset:');
  expect(await page.evaluate(()=>window.closePayload)).toBeNull();
  await page.evaluate(save=>window.tlSaveResult(save.requestId,true,save.proposedMarkdown),proposal);
  await expect.poll(()=>page.evaluate(()=>window.closePayload?.saved)).toBe(true);
  expect(await page.evaluate(()=>window.closePayload.proposedMarkdown)).toBe(proposal.proposedMarkdown);
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await expect(page.locator('#source')).toHaveValue(proposal.proposedMarkdown);
  await load(page,proposal.proposedMarkdown);
  await expect(page.locator('#rich img[data-type="image-block"]')).toHaveAttribute('src','library-asset://local/media/rich.png');
  await expect(page.locator('#rich img[data-type="image-block"]')).toHaveAttribute('alt','pixel[1].png');
  expect(await page.evaluate(()=>window.nativeSaves)).toEqual([]);
});
test('rich image replaces selected text without losing surrounding paragraphs and supports undo',async({page})=>{
  await load(page,'left replace right\n');
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  await page.locator('#rich .ProseMirror p').first().evaluate(paragraph=>{
    const range=document.createRange();range.setStart(paragraph.firstChild,5);range.setEnd(paragraph.firstChild,12);
    const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
  });
  await expect.poll(()=>page.evaluate(()=>window.getSelection()?.toString())).toBe('replace');
  const chooser=page.waitForEvent('filechooser');
  await page.getByRole('button',{name:'图片',exact:true}).click();
  await (await chooser).setFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  const image=page.locator('#rich img[data-type="image-block"]');
  await expect(image).toBeVisible();
  await expect.poll(()=>image.evaluate(element=>element.naturalWidth)).toBe(1);
  const inserted=await page.evaluate(()=>window.tlGetMarkdown());
  expect(inserted).toContain('left');expect(inserted).toContain('right');
  expect(inserted).not.toContain('replace');expect(inserted).toContain('data:image/png;base64,');
  await page.keyboard.press('ControlOrMeta+z');
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toBe('left replace right\n');
  await expect(image).toHaveCount(0);
  await page.keyboard.press('ControlOrMeta+Shift+z');
  await expect(image).toBeVisible();
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(inserted);
});
test('rich image in an empty note renders and reopens with optional caption intact',async({page})=>{
  await load(page,'');
  await page.locator('#image-file').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  const image=page.locator('#rich img[data-type="image-block"]');
  await expect(image).toBeVisible();
  await expect.poll(()=>image.evaluate(element=>element.naturalWidth)).toBe(1);
  const inserted=await page.evaluate(()=>window.tlGetMarkdown());
  await load(page,inserted);
  await expect(image).toBeVisible();
  await expect.poll(()=>image.evaluate(element=>element.naturalWidth)).toBe(1);
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(inserted);
  const withCaption=inserted.replace(/\)\s*$/, ' "研究图片说明")\n');
  await load(page,withCaption);
  await expect(image).toHaveAttribute('alt','pixel.png');
  await expect(page.locator('#rich .caption-input')).toHaveValue('研究图片说明');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(withCaption);
});
test('standard image descriptions and captions survive rich edits, source, read and reopening',async({page})=>{
  const imageData='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=';
  await load(page,`![研究图：甲 & 乙](${imageData} "原作者说明")\n\n正文\n`);
  const image=page.locator('#rich img[data-type="image-block"]');
  await expect(image).toHaveAttribute('alt','研究图：甲 & 乙');
  await expect(page.getByRole('img',{name:'研究图：甲 & 乙',exact:true})).toBeVisible();
  await expect(page.locator('#rich .caption-input')).toHaveValue('原作者说明');
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  for(let index=0;index<20;index++) await page.keyboard.press('ArrowRight');
  await page.keyboard.type(' saved');
  const saved=await page.evaluate(()=>window.tlGetMarkdown());
  expect(saved).toContain(`![研究图：甲 & 乙](${imageData} "原作者说明")`);
  expect(saved).not.toContain('tokenlibrary-image:');
  await page.getByRole('button',{name:'源码',exact:true}).click();
  await expect(page.locator('#source')).toHaveValue(saved);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview img')).toHaveAttribute('alt','研究图：甲 & 乙');
  await load(page,saved);
  await expect(image).toHaveAttribute('alt','研究图：甲 & 乙');
  await expect(page.locator('#rich .caption-input')).toHaveValue('原作者说明');
});
test('legacy image descriptions stay readable when switching rich to read without any edit',async({page})=>{
  const imageData='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=';
  const original=`![0.50](${imageData} "流程关系图 &amp; 对照")\n\n![1.00](${imageData})\n\n![1.00](${imageData} "明确数字描述")\n\n<!-- tokenlibrary-image:v1 ratio=1 -->\n\n![2024](${imageData})\n\n![0.80](${imageData} "&quot;图&quot; &lt;甲&gt;")\n\n正文不改。\n`;
  await load(page);
  await page.evaluate(value=>{
    window.changes=[];window.addEventListener('tl-change',event=>window.changes.push(event.detail));
    window.tlSetMarkdown(value);
  },original);
  const expected=['流程关系图 & 对照','图片','1.00','2024','"图" <甲>'];
  for(let index=0;index<expected.length;index++) await expect(page.locator('#rich img[data-type="image-block"]').nth(index)).toHaveAttribute('alt',expected[index]);
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  for(let index=0;index<expected.length;index++) await expect(page.locator('#preview img').nth(index)).toHaveAttribute('alt',expected[index]);
  await expect(page.getByRole('img',{name:'流程关系图 & 对照',exact:true})).toBeVisible();
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(original);
  expect(await page.evaluate(()=>window.changes)).toEqual([]);
  // Read-only archived opening takes the same display path, without first
  // saving Milkdown's normalized Markdown back to the library.
  await page.reload();await page.waitForFunction(()=>window.tlEditorReady);
  await page.evaluate(value=>{
    window.changes=[];window.addEventListener('tl-change',event=>window.changes.push(event.detail));
    window.tlSetMarkdown(value);window.tlSetReadOnly(true);
  },original);
  await expect(page.getByRole('img',{name:'流程关系图 & 对照',exact:true})).toBeVisible();
  await expect(page.locator('#preview img').nth(2)).toHaveAttribute('alt','1.00');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(original);
  expect(await page.evaluate(()=>window.changes)).toEqual([]);
});
test('legacy numeric image ratio retains caption, resizing and semantic alt after saving',async({page})=>{
  await load(page);
  const imageData=await page.evaluate(()=>{
    const canvas=document.createElement('canvas');canvas.width=240;canvas.height=180;
    const context=canvas.getContext('2d');context.fillStyle='#236854';context.fillRect(0,0,240,180);
    return canvas.toDataURL('image/png');
  });
  const legacy=`![0.50](${imageData} "流程关系图")\n\n正文\n`;
  await page.evaluate(value=>{
    window.changes=[];window.addEventListener('tl-change',event=>window.changes.push(event.detail));
    window.tlSetMarkdown(value);
  },legacy);
  const image=page.locator('#rich img[data-type="image-block"]');
  await expect(image).toHaveAttribute('alt','流程关系图');
  await expect.poll(()=>image.evaluate(element=>element.dataset.height)).toBe('90.00');
  expect(await page.evaluate(()=>window.tlGetMarkdown())).toBe(legacy);
  expect(await page.evaluate(()=>window.changes)).toEqual([]);
  await image.click();
  const box=await image.boundingBox(),handle=await page.locator('#rich .image-resize-handle').boundingBox();
  await page.mouse.move(handle.x+handle.width/2,handle.y+handle.height/2);
  await page.mouse.down();await page.mouse.move(handle.x+handle.width/2,box.y+135);await page.mouse.up();
  await expect.poll(()=>page.evaluate(()=>window.tlGetMarkdown())).toContain('<!-- tokenlibrary-image:v1 ratio=0.75 -->');
  let saved=await page.evaluate(()=>window.tlGetMarkdown());
  expect(saved).toContain(`![流程关系图](${imageData} "流程关系图")`);
  await load(page,saved);
  await expect(image).toHaveAttribute('alt','流程关系图');
  await expect.poll(()=>image.evaluate(element=>element.dataset.height)).toBe('135.00');
  const caption=page.locator('#rich .caption-input');
  await caption.fill('补充说明');await caption.press('Tab');
  saved=await page.evaluate(()=>window.tlGetMarkdown());
  expect(saved).toContain(`![流程关系图](${imageData} "补充说明")`);
  expect(saved).toContain('<!-- tokenlibrary-image:v1 ratio=0.75 -->');
  await expect(image).toHaveAttribute('alt','流程关系图');
  await load(page,saved);
  await expect(page.locator('#rich .caption-input')).toHaveValue('补充说明');
  await expect.poll(()=>image.evaluate(element=>element.dataset.height)).toBe('135.00');
  await page.getByRole('button',{name:'阅读',exact:true}).click();
  await expect(page.locator('#preview img')).toHaveAttribute('alt','流程关系图');
  await expect(page.locator('#preview')).not.toContainText('tokenlibrary-image:');
});
test('ordinary numeric alt and explicit numeric descriptions do not become legacy scaling',async({page})=>{
  const imageData='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=';
  await load(page,`![2024](${imageData})\n\n![1.00](${imageData})\n\n<!-- tokenlibrary-image:v1 ratio=1 -->\n\n![1.00](${imageData})\n\n正文\n`);
  const images=page.locator('#rich img[data-type="image-block"]');
  await expect(images).toHaveCount(3);
  await expect(images.nth(0)).toHaveAttribute('alt','2024');
  await expect(images.nth(1)).toHaveAttribute('alt','1.00');
  await expect(images.nth(2)).toHaveAttribute('alt','图片');
  await page.getByRole('textbox',{name:'笔记正文',exact:true}).click();
  for(let index=0;index<20;index++) await page.keyboard.press('ArrowRight');
  await page.keyboard.type(' saved');
  const saved=await page.evaluate(()=>window.tlGetMarkdown());
  expect(saved).toContain(`![2024](${imageData})`);
  expect(saved).toContain(`![1.00](${imageData})\n\n<!-- tokenlibrary-image:v1 ratio=1 -->`);
  expect(saved).toContain(`![图片](${imageData})`);
  await load(page,saved);
  await expect(images.nth(0)).toHaveAttribute('alt','2024');
  await expect(images.nth(1)).toHaveAttribute('alt','1.00');
  await expect(images.nth(2)).toHaveAttribute('alt','图片');
});
test('closing waits for the in-flight result and preserves a failed proposal base',async({page})=>{
  await nativeLoad(page,'base');
  await page.getByRole('textbox',{name:'Markdown 源码'}).fill('local proposal');
  await page.evaluate(()=>{window.closePayload=null;window.tlFlushEdit().then(value=>window.closePayload=value);});
  expect(await page.evaluate(()=>window.closePayload)).toBeNull();
  await page.evaluate(()=>window.tlSaveResult(1,false,'remote proposal','草稿保留'));
  await expect.poll(()=>page.evaluate(()=>window.closePayload)).toEqual({baseMarkdown:'base',proposedMarkdown:'local proposal',saved:false});
});

test('durable conflict continues autosaving new draft text without replacing the original base',async({page})=>{
  await nativeLoad(page,'base');
  const source=page.getByRole('textbox',{name:'Markdown 源码'});
  await source.fill('draft one');
  await page.evaluate(()=>window.tlSaveResult(1,false,'remote','草稿已保存',true));
  await source.fill('draft two');
  const saves=await page.evaluate(()=>window.nativeSaves);
  expect(saves).toHaveLength(2);expect(saves[1].baseMarkdown).toBe('base');expect(saves[1].proposedMarkdown).toBe('draft two');
  expect(await page.evaluate(()=>window.tlAcceptUpdate('remote'))).toBe(false);
  await page.evaluate(()=>window.tlSaveResult(2,false,'remote','草稿已更新',true));
  const flushed=await page.evaluate(()=>window.tlFlushEdit());
  expect(flushed.saved).toBe(false);expect(flushed.proposedMarkdown).toBe('draft two');
});
test('closing waits until native image import is inserted and saved',async({page})=>{
  await nativeLoad(page,'');
  await page.locator('#image-file').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jU1kAAAAASUVORK5CYII=','base64')});
  await page.evaluate(()=>{window.closePayload=null;window.tlFlushEdit().then(value=>window.closePayload=value);});
  expect(await page.evaluate(()=>window.closePayload)).toBeNull();
  await expect.poll(()=>page.evaluate(()=>window.nativeUploads.length)).toBe(1);
  await page.evaluate(()=>window.tlAttachmentResult(window.nativeUploads[0].id,'media/last.png',null));
  await expect.poll(()=>page.evaluate(()=>window.nativeSaves.length)).toBe(1);
  await page.evaluate(()=>{const save=window.nativeSaves[0];window.tlSaveResult(save.requestId,true,save.proposedMarkdown);});
  await expect.poll(()=>page.evaluate(()=>window.closePayload?.saved)).toBe(true);
  expect(await page.evaluate(()=>window.closePayload.proposedMarkdown)).toContain('media/last.png');
});

test('rich source links keep the internal route and version while unsafe protocols stay blocked',async({page})=>{
  const url='tokenlibrary://document/01234567-89ab-cdef-0123-456789abcdef?page=3&hash=abc123';
  await nativeLoad(page,`[来源资料](${url})\n\n[危险](javascript:alert(1))\n`);
  await page.getByRole('button',{name:'排版',exact:true}).click();
  await expect(page.locator('#rich a').filter({hasText:'来源资料'})).toHaveAttribute('href',url);
  expect(await page.locator('#rich a[href^="javascript:"]').count()).toBe(0);
  await page.locator('#rich a').filter({hasText:'来源资料'}).click();
  expect(await page.evaluate(()=>window.nativeLinks)).toContain(url);
  await page.getByRole('button',{name:'源码',exact:true}).click();
  expect(await page.getByRole('textbox',{name:'Markdown 源码'}).inputValue()).toContain(url);
});
