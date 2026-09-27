import { $remark } from '@milkdown/kit/utils';
import { editorViewCtx } from '@milkdown/kit/core';
import { imageBlockSchema } from '@milkdown/kit/component/image-block';

// Crepe previously serialized its resize ratio into alt with exactly two
// decimals. New images keep standard Markdown descriptions and use an adjacent
// HTML comment only when a size (or an ambiguous numeric description) needs it.
const legacyRatio = /^\d+\.\d{2}$/;
const scaleComment = /^<!--\s*tokenlibrary-image:v1 ratio=(\d+(?:\.\d+)?(?:e[+-]?\d+)?)\s*-->$/i;
const validScale = value => Number.isFinite(value) && value > 0;
const isLegacyImageRatio = (alt, explicitScale) => !explicitScale && legacyRatio.test(alt) && validScale(Number(alt));

// Marked creates these tokens for this render only. Apply the same old block-
// image convention as the rich parser without normalizing the stored Markdown.
export function prepareReadImageDescriptions(tokens) {
  const visit = blocks => {
    for (let index = 0; index < blocks.length; index++) {
      const block = blocks[index];
      if (['paragraph', 'text'].includes(block.type) && block.tokens?.length === 1 && block.tokens[0].type === 'image') {
        const image = block.tokens[0];
        let next = index + 1;
        while (blocks[next]?.type === 'space') next++;
        const match = blocks[next]?.type === 'html' && scaleComment.exec(blocks[next].text.trim());
        const explicitScale = Boolean(match && validScale(Number(match[1])));
        if (isLegacyImageRatio(image.text, explicitScale)) {
          // The text renderer used for image alt expects escaped inline text.
          // Retain existing entities in a title, as Marked's title renderer does.
          const label = (image.title || '图片')
            .replace(/&(?!(?:#\d+|#x[\da-f]+|[a-z][\da-z]*);)/gi, '&amp;')
            .replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          image.text = label;
          image.tokens = [{type: 'text', text: label}];
        }
      }
      if (block.type === 'blockquote') visit(block.tokens);
      if (block.type === 'list') for (const item of block.items) visit(item.tokens);
    }
  };
  visit(tokens);
  return tokens;
}

const imageMetadata = $remark('tokenlibrary-image-metadata', () => () => tree => {
  const visit = parent => {
    if (!Array.isArray(parent.children)) return;
    for (let index = 0; index < parent.children.length; index++) {
      const node = parent.children[index], next = parent.children[index + 1];
      // CommonMark's HTML transformer can wrap a standalone comment in a
      // paragraph before our plugin runs. Consume only this exact marker, never
      // arbitrary nearby HTML or a paragraph containing other content.
      const metadata = next?.type === 'html' ? next : next?.type === 'paragraph' && next.children?.length === 1 && next.children[0].type === 'html' ? next.children[0] : null;
      if (node.type === 'image-block' && metadata) {
        const match = scaleComment.exec(String(metadata.value).trim());
        const ratio = match && Number(match[1]);
        if (validScale(ratio)) {
          node.tokenLibraryScale = ratio;
          parent.children.splice(index + 1, 1);
        }
      }
      visit(node);
    }
  };
  visit(tree);
});

export function configureImageDescriptions(editor) {
  editor.use(imageMetadata).config(ctx => {
    ctx.update(imageBlockSchema.key, previous => context => {
      const schema = previous(context);
      return {
        ...schema,
        attrs: {...schema.attrs, alt: {default: '', validate: 'string'}},
        parseDOM: schema.parseDOM.map(rule => ({...rule, getAttrs(dom) {
          const attrs = rule.getAttrs?.(dom);
          if (attrs === false) return false;
          return {...attrs, alt: dom.getAttribute('alt') || ''};
        }})),
        parseMarkdown: {...schema.parseMarkdown, runner(state, node, type) {
          const caption = typeof node.title === 'string' ? node.title : '';
          const originalAlt = typeof node.alt === 'string' ? node.alt : '';
          const explicitScale = validScale(node.tokenLibraryScale);
          const legacy = isLegacyImageRatio(originalAlt, explicitScale);
          state.addNode(type, {
            src: node.url, caption,
            alt: legacy ? (caption || '图片') : originalAlt,
            ratio: explicitScale ? node.tokenLibraryScale : legacy ? Number(originalAlt) : 1,
          });
        }},
        toMarkdown: {...schema.toMarkdown, runner(state, node) {
          const {src, caption, alt} = node.attrs;
          const ratio = validScale(node.attrs.ratio) ? node.attrs.ratio : 1;
          state.openNode('paragraph');
          state.addNode('image', undefined, undefined, {url: src, title: caption, alt});
          state.closeNode();
          if (ratio !== 1 || legacyRatio.test(alt)) {
            state.addNode('html', undefined, `<!-- tokenlibrary-image:v1 ratio=${ratio} -->`);
          }
        }},
      };
    });
  });
}

export function installImageDescriptions(editor) {
  editor.action(ctx => {
    const view = ctx.get(editorViewCtx), create = view.props.nodeViews?.['image-block'];
    if (!create) return;
    view.setProps({nodeViews: {...view.props.nodeViews, 'image-block': (...args) => {
      let node = args[0], active = true;
      const original = create(...args);
      const refresh = () => {
        if (!active) return;
        const label = node.attrs.alt || node.attrs.caption || '图片';
        original.dom.querySelectorAll('img[data-type="image-block"]').forEach(image => {
          if (image.getAttribute('alt') !== label) image.setAttribute('alt', label);
        });
      };
      // Keep Crepe's caption/resize/upload view intact. Vue may update its own
      // caption-derived alt asynchronously, or replace an empty upload view.
      const observer = new MutationObserver(refresh);
      observer.observe(original.dom, {subtree: true, childList: true, attributes: true, attributeFilter: ['alt']});
      refresh();
      return {...original,
        update(updated, ...rest) {
          const accepted = original.update?.(updated, ...rest) ?? false;
          if (accepted) { node = updated; refresh(); }
          return accepted;
        },
        destroy() { active = false; observer.disconnect(); original.destroy?.(); },
      };
    }}});
  });
}
