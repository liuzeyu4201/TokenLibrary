import { Crepe } from '@milkdown/crepe';
import { insert, callCommand } from '@milkdown/kit/utils';
import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { Slice } from '@milkdown/kit/prose/model';
import { closeHistory } from '@milkdown/kit/prose/history';
import { configureImageDescriptions, installImageDescriptions, prepareReadImageDescriptions } from './images.js';
import { updateSourceValue } from './source-selection.js';
import { updateRichDocument } from './rich-updates.js';
import { toggleStrongCommand, toggleEmphasisCommand, wrapInHeadingCommand, wrapInBulletListCommand, linkSchema } from '@milkdown/kit/preset/commonmark';
import { Marked } from 'marked';
import DOMPurify from 'dompurify';
import katex from 'katex';
import mermaid from 'mermaid';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame.css';
import 'katex/dist/katex.min.css';
import './styles.css';

const native = (name, value) => window.webkit?.messageHandlers?.[name]?.postMessage(value);
const escapeHTML = text => String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const assetURL = url => /^media\/[a-zA-Z0-9._-]+$/.test(url) && window.webkit
  ? `library-asset://local/${url}` : url;
const source = document.getElementById('source');
const rich = document.getElementById('rich');
const preview = document.getElementById('preview');
const status = document.getElementById('status');
const errorBox = document.getElementById('error');
let markdown = '', mode = 'edit', crepe, ready = false, suppress = false, readOnly = false;
let renderVersion = 0, diagramId = 0, richDiagramRequest = 0, pendingReplace, richMarkdown = '', saveFailed = false;
let editBase = '', saveInFlight = null, saveSequence = 0, hasConflict = false;
let sourceComposing = false, deferredSourceRefresh = null;
let sourceTabExitArmed = false;
const pendingMedia = new Set();
const uploads = new Map();
const showError = error => { errorBox.textContent = error?.message || String(error); errorBox.hidden = false; };
const clearError = () => { errorBox.hidden = true; errorBox.textContent = ''; };
const notify = value => {
  markdown = value;
  // Reassigning a textarea value during marked-text input can end the native
  // input method's composition. Ordinary source input already has this value.
  updateSourceValue(source,value);
  status.textContent = sourceComposing ? '输入法正在组合文字…' : window.webkit ? '正在保存到本机…' : '浏览器预览 · 内容尚未写入资料库';
  sendSave();
  window.dispatchEvent(new CustomEvent('tl-change', {detail: value}));
};
function sendSave() {
  if (!window.webkit?.messageHandlers?.tlSave || sourceComposing || saveInFlight || saveFailed || markdown === editBase) return;
  saveInFlight = {requestId: ++saveSequence, baseMarkdown: editBase, proposedMarkdown: markdown};
  native('tlSave', saveInFlight);
}
// One request at a time keeps each subsequent edit based on the text it actually
// followed, even when the native store merges an intervening remote change.
window.tlSaveResult = (requestId, ok, canonical, message, durableConflict = false) => {
  if (!saveInFlight || saveInFlight.requestId !== requestId) return;
  const submitted = saveInFlight.proposedMarkdown;
  saveInFlight = null;
  // Capture the final rich transaction before an acknowledgement can replace it.
  if (mode === 'edit' && ready) {
    const current = crepe.getMarkdown();
    if (current !== richMarkdown) { richMarkdown = current; markdown = current; updateSourceValue(source,current); }
  }
  window.tlSaved(ok, message, durableConflict);
  if (!ok) {
    if (durableConflict && markdown !== submitted) sendSave();
    window.dispatchEvent(new Event('tl-save-result'));return;
  }
  if (markdown === submitted && !sourceComposing) {
    editBase = canonical;
    if (canonical !== markdown) window.tlSetMarkdown(canonical);
  } else {
    editBase = submitted;
    if (sourceComposing && canonical !== submitted) deferredSourceRefresh = {value:canonical,expected:submitted};
  }
  sendSave();
  window.dispatchEvent(new Event('tl-save-result'));
};
window.tlSaved = (ok, message, durableConflict = false) => {
  saveFailed = !ok && !durableConflict;hasConflict = durableConflict;
  status.textContent = ok ? (sourceComposing ? '输入法正在组合文字…' : '已保存到本机') : durableConflict ? '冲突草稿已保存到本机' : '保存失败 · 内容仍在编辑器中';
  document.getElementById('retry-save').hidden = ok || durableConflict;
  if (!ok) showError(message || '请保留当前页面并重试保存。');
  else clearError();
};
mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
  maxTextSize: 100000, maxEdges: 1000, theme: 'neutral', htmlLabels: false });
async function diagram(content) {
  if (!/^\s*(flowchart|graph)\b/.test(content)) throw new Error('图表请使用 flowchart 或 graph 流程图语法。源码已保留。');
  const { svg } = await mermaid.render(`tl-diagram-${++diagramId}`, content);
  const container = document.createElement('div');
  container.className = 'diagram';
  container.innerHTML = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true }, ADD_TAGS: ['style'] });
  return container;
}
function richDiagramPreview(language, content, apply) {
  if (language.toLowerCase() !== 'mermaid') return null;
  const request = String(++richDiagramRequest);
  const holder = document.createElement('div');
  holder.dataset.tlDiagramRequest = request;
  holder.textContent = '正在绘制流程图…';
  const complete = result => requestAnimationFrame(() => {
    // Milkdown sanitizes and copies the returned DOM; mutating `holder` cannot
    // update that copy. Apply a fresh value only while this request is mounted.
    // The frame also lets Vue mount its first placeholder before a fast result.
    if (rich.querySelector(`[data-tl-diagram-request="${request}"]`)) apply(result);
  });
  diagram(content).then(complete).catch(error => {
    const message = document.createElement('div');
    message.className = 'render-error'; message.setAttribute('role', 'alert');
    message.textContent = `流程图错误：${error.message || error}`;
    complete(message);
  });
  return holder;
}
const parser = new Marked({ gfm: true, breaks: false });
parser.use({ hooks: {processAllTokens: prepareReadImageDescriptions} });
const mathHTML = (text, displayMode) => {
  try { return katex.renderToString(text, { displayMode, throwOnError: true, trust: false, strict: 'warn', maxExpand: 1000 }); }
  catch (error) { return `<span class="render-error" role="alert">公式错误：${escapeHTML(error.message)}<code>${escapeHTML(text)}</code></span>`; }
};
parser.use({ extensions: [
  { name: 'blockMath', level: 'block', start: text => text.indexOf('$$'),
    tokenizer(text) { const match = /^\$\$[ \t]*\n?([\s\S]+?)\n?\$\$[ \t]*(?:\n|$)/.exec(text); if (match) return {type:'blockMath', raw:match[0], text:match[1]}; },
    renderer: token => `<div class="math-block">${mathHTML(token.text, true)}</div>` },
  { name: 'inlineMath', level: 'inline', start: text => text.indexOf('$'),
    tokenizer(text) { const match = /^\$(?!\$|\s)((?:\\.|[^$\n])+?)\$(?!\$)/.exec(text); if (match) return {type:'inlineMath', raw:match[0], text:match[1]}; },
    renderer: token => mathHTML(token.text, false) },
] });
async function renderPreview() {
  const version = ++renderVersion;
  const readable = markdown.replace(/<!--\/?tl:(?:text|image|voice)\b[^>]*-->/g, "\n");
  preview.innerHTML = DOMPurify.sanitize(parser.parse(readable), {
    ADD_ATTR: ['target'], ALLOW_UNKNOWN_PROTOCOLS: false,
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|library-asset|tokenlibrary):|data:image\/(?:png|jpeg|gif|webp);|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
  });
  preview.querySelectorAll('img').forEach(img => { img.src = assetURL(img.getAttribute('src') || ''); img.loading = 'lazy'; });
  preview.querySelectorAll('a').forEach(link => { link.rel = 'noopener noreferrer'; });
  for (const block of preview.querySelectorAll('pre code.language-mermaid')) {
    try {
      const result = await diagram(block.textContent);
      if (version !== renderVersion) return;
      block.parentElement.replaceWith(result);
    } catch (error) {
      if (version !== renderVersion) return;
      const message = document.createElement('p'); message.className = 'render-error';
      message.textContent = `流程图错误：${error.message || error}`;
      block.parentElement.before(message);
    }
  }
  // Legacy voice blocks remain ordinary Markdown links on disk, playable here.
  preview.querySelectorAll('a').forEach(link => {
    const path = link.getAttribute('href') || '';
    if (/^media\/[a-zA-Z0-9._-]+\.(m4a|mp3|wav|aac)$/i.test(path)) {
      const audio = document.createElement('audio'); audio.controls = true; audio.preload = 'none'; audio.src = assetURL(path);
      link.replaceWith(audio);
    }
  });
}
function setRich(value) {
  if (!ready) { pendingReplace = value; return; }
  if (richMarkdown === value) return;
  suppress = true;
  try {
    crepe.editor.action(ctx=>{
      const next=ctx.get(parserCtx)(value);
      if(!next)throw new Error('无法解析更新内容');
      updateRichDocument(ctx.get(editorViewCtx),next);
    });
    richMarkdown = crepe.getMarkdown();
  } catch (error) { showError(`排版编辑无法载入，源码仍保留：${error.message}`); switchMode('source'); }
  finally { suppress = false; }
}
function flushRichChanges() {
  if (ready && !suppress && mode === 'edit') {
    const current = crepe.getMarkdown();
    if (current !== richMarkdown) { richMarkdown = current;notify(current); }
  }
  return markdown;
}
function switchMode(next) {
  if (readOnly && next !== 'read') return;
  sourceTabExitArmed = false;
  flushRichChanges();
  mode = next;
  rich.hidden = next !== 'edit'; source.hidden = next !== 'source'; preview.hidden = next !== 'read';
  document.getElementById('source-keyboard-help').hidden = next !== 'source';
  document.getElementById('format-tools').hidden = next === 'read';
  document.querySelectorAll('[data-mode]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === next)));
  if (next === 'edit') setRich(markdown);
  if (next === 'source') updateSourceValue(source,markdown);
  if (next === 'read') renderPreview().catch(showError);
}
window.tlGetMarkdown = flushRichChanges;
window.tlFlush = flushRichChanges;
window.tlFlushEdit = async () => {
  if (sourceComposing) {
    showError('请先完成输入法候选，再离开或导出。当前文字仍在编辑器中。');
    return {baseMarkdown:editBase,proposedMarkdown:source.value,saved:false};
  }
  while (pendingMedia.size) {
    const results=await Promise.allSettled([...pendingMedia]);
    if (results.some(result=>result.status === 'rejected')) throw new Error('图片未能加入笔记，请重试后再离开。');
    await new Promise(requestAnimationFrame);
  }
  flushRichChanges();
  if (saveFailed) { saveFailed=false;sendSave(); }
  // Do not assume an in-flight proposal succeeded before closing/exporting.
  while (saveInFlight) {
    await new Promise((resolve,reject) => {
      const done=()=>{clearTimeout(timer);window.removeEventListener('tl-save-result',done);resolve();};
      const timer=setTimeout(()=>{window.removeEventListener('tl-save-result',done);reject(new Error('等待保存结果超时，内容仍保留。'));},30000);
      window.addEventListener('tl-save-result',done,{once:true});
    });
  }
  return {baseMarkdown:editBase,proposedMarkdown:markdown,saved:!sourceComposing && !saveFailed && !hasConflict};
};
window.addEventListener('pagehide', flushRichChanges);
document.addEventListener('visibilitychange', () => { if (document.hidden) flushRichChanges(); });
window.tlSetMarkdown = value => {
  if (typeof value !== 'string') return;
  if (value !== markdown) sourceTabExitArmed = false;
  if (sourceComposing) { deferredSourceRefresh={value};return; }
  markdown = value; editBase = value;
  updateSourceValue(source,value);
  clearError();
  // Legacy block markers and custom HTML are preserved verbatim in source mode.
  // The reader still renders their standard Markdown contents.
  if (/<!--\/?tl:|<(?:script|style|iframe)\b/i.test(value)) switchMode('source');
  else setRich(value);
  if (mode === 'read') renderPreview().catch(showError);
  status.textContent = window.webkit ? '已载入本机内容' : '浏览器预览 · 内容尚未写入资料库';
};
window.tlAcceptUpdate = (value, expected) => {
  if (sourceComposing) { deferredSourceRefresh={value,expected};return false; }
  if (saveFailed || hasConflict || saveInFlight) return false;
  const pendingInput = mode === 'edit' && ready && crepe.getMarkdown() !== richMarkdown;
  if (pendingInput || markdown !== editBase || (expected !== undefined && markdown !== expected)) {
    if (pendingInput) { richMarkdown=crepe.getMarkdown();notify(richMarkdown); }
    return false;
  }
  window.tlSetMarkdown(value); return true;
};
window.tlSetPreview = enabled => switchMode(enabled ? 'read' : 'edit');
window.tlSetReadOnly = enabled => {
  enabled=Boolean(enabled);
  if (readOnly === enabled) return;
  // Collect already typed text before a remote archive hides the editing surface.
  flushRichChanges();
  readOnly=enabled;
  source.readOnly=enabled;
  document.querySelectorAll('[data-mode]').forEach(button=>{button.disabled=enabled && button.dataset.mode!=='read';});
  switchMode(enabled ? 'read' : 'edit');
};
window.tlFind = text => {
  if (readOnly) { switchMode('read');window.find?.(String(text));return; }
  switchMode('source');
  const index = markdown.toLocaleLowerCase().indexOf(String(text).toLocaleLowerCase());
  if (index >= 0) { source.focus(); source.setSelectionRange(index, index + text.length); }
};
window.tlAttachmentResult = (id, path, error) => {
  const upload = uploads.get(id); if (!upload) return;
  clearTimeout(upload.timer); uploads.delete(id);
  if (error) upload.reject(new Error(error)); else upload.resolve(path);
};
function upload(file) {
  const operation=uploadFile(file);
  pendingMedia.add(operation);
  return operation.finally(()=>pendingMedia.delete(operation));
}
async function uploadFile(file) {
  if (!['image/png','image/jpeg','image/webp','image/gif'].includes(file.type)) throw new Error('图片支持 PNG、JPEG、WebP 和 GIF。');
  if (file.size > 20 * 1024 * 1024) throw new Error('图片超过 20 MB，请压缩后再插入。');
  const dataURL = await new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = reject; reader.readAsDataURL(file); });
  if (!window.webkit?.messageHandlers?.tlAttachment) return dataURL;
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    const timer = setTimeout(() => { uploads.delete(id); reject(new Error('保存图片超时，请重试；正文已保留。')); }, 30000);
    uploads.set(id, {resolve, reject, timer});
    native('tlAttachment', {id, name:file.name, mime:file.type, data:dataURL.split(',')[1]});
  });
}
function insertMarkdown(value, block = false) {
  if (readOnly) return;
  if (mode === 'source') {
    source.setRangeText(value, source.selectionStart, source.selectionEnd, 'end'); notify(source.value); source.focus();
  } else if (ready) {
    if (block) {
      crepe.editor.action(ctx => {
        const view = ctx.get(editorViewCtx), document = ctx.get(parserCtx)(value);
        if (!document) throw new Error('无法插入图片，请重试。');
        // Image blocks are atomic. A selected text range has open paragraph
        // edges; Milkdown's generic insert copies those edges and drops the
        // image. Keep this block closed while replacing the current selection.
        // One image insertion is one undo step, even immediately after loading
        // the note or typing adjacent text.
        view.dispatch(closeHistory(view.state.tr).replaceSelection(new Slice(document.content, 0, 0)).scrollIntoView());
      });
    } else crepe.editor.action(insert(value));
    crepe.editor.action(ctx => ctx.get(editorViewCtx).focus());
  }
}
source.addEventListener('compositionstart', () => { sourceTabExitArmed=false;sourceComposing=true; });
source.addEventListener('compositionend', () => {
  sourceComposing=false;
  const deferred=deferredSourceRefresh;deferredSourceRefresh=null;
  if (!readOnly) { clearError();notify(source.value); }
  // Cancelling marked text may leave no local change to save. In that case the
  // queued host refresh can be applied now. Otherwise the next native save
  // merges the committed text against its original base and returns canonical.
  if (deferred && !saveInFlight && markdown === editBase) window.tlAcceptUpdate(deferred.value,deferred.expected);
});
source.addEventListener('input', () => { sourceTabExitArmed=false;if (!readOnly) { clearError(); notify(source.value); } });
source.addEventListener('blur', () => { sourceTabExitArmed=false; });
source.addEventListener('keydown', event => {
  // Escape belongs to the input method while marked text is active. A plain
  // Escape otherwise makes only the next Tab a native focus-navigation key.
  if (sourceComposing || event.isComposing || event.keyCode === 229) { sourceTabExitArmed=false;return; }
  if (event.key === 'Escape' && !event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey) {
    sourceTabExitArmed=true;event.preventDefault();event.stopPropagation();return;
  }
  if (event.key !== 'Tab') { sourceTabExitArmed=false;return; }
  const navigate = sourceTabExitArmed || event.shiftKey || event.ctrlKey || event.altKey || event.metaKey;
  sourceTabExitArmed=false;
  if (!navigate) { event.preventDefault(); insertMarkdown('    '); }
});
document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => switchMode(button.dataset.mode)));
const commands = {bold: toggleStrongCommand, italic: toggleEmphasisCommand, heading: wrapInHeadingCommand, list: wrapInBulletListCommand};
const sourceFormats = {bold:['**','**'], italic:['*','*'], heading:['## ',''], list:['- ','']};
document.querySelectorAll('[data-command]').forEach(button => {
  button.addEventListener('mousedown', event => event.preventDefault());
  button.addEventListener('click', () => {
    if (readOnly) return;
    const name = button.dataset.command;
    if (mode === 'source') {
      const [start,end] = sourceFormats[name], selection = source.value.slice(source.selectionStart,source.selectionEnd);
      insertMarkdown(start + (selection || '文字') + end);
    } else if (ready) { crepe.editor.action(callCommand(commands[name].key, name === 'heading' ? 2 : undefined)); crepe.editor.action(ctx => ctx.get(editorViewCtx).focus()); }
  });
});
document.getElementById('insert-diagram').onclick = () => insertMarkdown('\n```mermaid\nflowchart LR\n  A[问题] --> B[研究]\n  B --> C[结论]\n```\n');
document.getElementById('insert-math').onclick = () => insertMarkdown('\n$$\nE = mc^2\n$$\n');
document.getElementById('retry-save').onclick = () => { saveFailed=false;notify(markdown); };
document.getElementById('insert-image').onclick = () => document.getElementById('image-file').click();
document.getElementById('image-file').onchange = async event => {
  const file = event.target.files[0]; if (!file) return;
  try {
    clearError();
    const path = await upload(file);
    const label = file.name.replaceAll('\\', '\\\\').replaceAll('[', '\\[').replaceAll(']', '\\]');
    insertMarkdown(`\n![${label}](${path})\n`, true);
  }
  catch (error) { showError(error); }
  finally { event.target.value = ''; }
};
document.addEventListener('click', event => {
  const link = event.target.closest('a'); if (!link) return;
  const url = link.getAttribute('href') || '';
  if (/^https?:|^mailto:|^tokenlibrary:/i.test(url) && window.webkit) { event.preventDefault(); native('tlOpenLink', url); }
});
async function start() {
  crepe = new Crepe({ root: rich, defaultValue:'', features:{[Crepe.Feature.AI]:false}, featureConfigs:{
    [Crepe.Feature.Placeholder]: {text:'开始记录你的想法…'},
    [Crepe.Feature.ImageBlock]: { onUpload:upload, inlineOnUpload:upload, blockOnUpload:upload, proxyDomURL:assetURL,
      blockUploadButton:'选择图片', inlineUploadButton:'选择图片', blockCaptionPlaceholderText:'图片说明',
      onImageLoadError: () => showError('图片暂不可用。同步完成后重新打开笔记可重试。') },
    [Crepe.Feature.CodeMirror]: { languages:[], copyText:'复制', searchPlaceholder:'代码语言', noResultText:'无匹配语言',
      previewLabel:'预览', previewLoading:'正在绘制…', previewToggleText: hidden => hidden ? '编辑源码' : '收起源码',
      renderPreview: richDiagramPreview },
    [Crepe.Feature.Latex]: {katexOptions:{trust:false, maxExpand:1000}},
  }});
  configureImageDescriptions(crepe.editor);
  crepe.editor.config(ctx => {
    ctx.update(linkSchema.key, previous => context => {
      const schema=previous(context);
      return {...schema,toDOM(mark) {
        const dom=schema.toDOM(mark);
        // Keep the upstream URL allowlist for all other protocols. Only the
        // app's document route is added for source navigation in rich mode.
        if (/^tokenlibrary:\/\/document\/[a-z0-9-]+(?:\?[^#\s]*)?$/i.test(mark.attrs.href) && Array.isArray(dom)) {
          return [dom[0],{...dom[1],href:mark.attrs.href},...dom.slice(2)];
        }
        return dom;
      }};
    });
  });
  crepe.on(listener => listener.markdownUpdated((ctx, value) => {
    // Parser initialization and remote updates must never autosave normalized source.
    if (!ready || suppress || mode !== 'edit') return;
    if (value === richMarkdown) return;
    richMarkdown = value;
    notify(value);
  }));
  await crepe.create();
  installImageDescriptions(crepe.editor);
  ready = true;
  rich.querySelector('.ProseMirror')?.setAttribute('aria-label', '笔记正文');
  rich.querySelector('.ProseMirror')?.setAttribute('role', 'textbox');
  rich.querySelector('.ProseMirror')?.setAttribute('aria-multiline', 'true');
  if (pendingReplace !== undefined) { const value=pendingReplace;pendingReplace=undefined;setRich(value); }
  window.tlEditorReady = true; native('tlReady', true); window.dispatchEvent(new Event('tl-ready'));
}
start().catch(error => {showError(`编辑器启动失败，可继续编辑源码：${error.message}`);switchMode('source');native('tlReady',true);});
