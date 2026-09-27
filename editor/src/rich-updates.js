import { matchingSegments, textReplacements } from './source-selection.js';

// Preserve ProseMirror's own selection/bookmark mapping by changing only the
// affected ranges. Replacing 0...doc.size treats every caret as deleted, even
// when the paragraph the user is typing in is completely unchanged.
export function updateRichDocument(view, next) {
  const previous=view.state.doc;
  if(previous.eq(next))return;
  const edits=[],formats=[];
  const replace=(from,to,insertFrom,insertTo)=>edits.push({from,to,insertFrom,insertTo});
  const children=(node,start)=>{
    const items=[],offsets=[start];
    node.forEach(child=>{items.push(child);offsets.push(offsets.at(-1)+child.nodeSize);});
    return {items,offsets};
  };
  const onlyText=node=>{let result=true;node.forEach(child=>{if(!child.isText)result=false;});return result;};
  const compareNode=(oldNode,newNode,oldAt,newAt)=>{
    if(oldNode.eq(newNode))return;
    if(!oldNode.sameMarkup(newNode)) {
      replace(oldAt,oldAt+oldNode.nodeSize,newAt,newAt+newNode.nodeSize);return;
    }
    if(oldNode.isTextblock && onlyText(oldNode) && onlyText(newNode)) {
      // Marks split/merge adjacent text nodes. Compare their combined text,
      // then change formatting with mark steps that do not delete any caret.
      for(const edit of textReplacements(oldNode.textContent,newNode.textContent))
        replace(oldAt+1+edit.from,oldAt+1+edit.to,newAt+1+edit.insertFrom,newAt+1+edit.insertTo);
      formats.push({node:newNode,at:newAt+1});
    } else if(oldNode.isText) {
      for(const edit of textReplacements(oldNode.text,newNode.text))
        replace(oldAt+edit.from,oldAt+edit.to,newAt+edit.insertFrom,newAt+edit.insertTo);
    } else compareChildren(oldNode,newNode,oldAt+1,newAt+1);
  };
  const compareChildren=(oldParent,newParent,oldAt,newAt)=>{
    const old=children(oldParent,oldAt),fresh=children(newParent,newAt);
    const keys=items=>items.map(node=>JSON.stringify(node.toJSON()));
    const structure=node=>JSON.stringify([node.type.name,node.attrs,node.marks.map(mark=>mark.toJSON())]);
    const compareGap=(aStart,aEnd,bStart,bEnd)=>{
      if(aEnd-aStart===bEnd-bStart) {
        for(let index=0;index<aEnd-aStart;index++)
          compareNode(old.items[aStart+index],fresh.items[bStart+index],old.offsets[aStart+index],fresh.offsets[bStart+index]);
        return;
      }
      // A newly inserted paragraph must not cause an adjacent changed list or
      // quote to be replaced wholesale. Exact unchanged children anchor first;
      // within each remaining gap align compatible structures recursively.
      const anchors=matchingSegments(old.items.slice(aStart,aEnd).map(structure),fresh.items.slice(bStart,bEnd).map(structure));
      let a=aStart,b=bStart;
      for(const [relativeA,relativeB] of anchors) {
        const matchedA=aStart+relativeA,matchedB=bStart+relativeB;
        if(a!==matchedA || b!==matchedB)replace(old.offsets[a],old.offsets[matchedA],fresh.offsets[b],fresh.offsets[matchedB]);
        compareNode(old.items[matchedA],fresh.items[matchedB],old.offsets[matchedA],fresh.offsets[matchedB]);
        a=matchedA+1;b=matchedB+1;
      }
      if(a!==aEnd || b!==bEnd)replace(old.offsets[a],old.offsets[aEnd],fresh.offsets[b],fresh.offsets[bEnd]);
    };
    const matches=matchingSegments(keys(old.items),keys(fresh.items));
    let oldStart=0,newStart=0;
    for(const [a,b] of [...matches,[old.items.length,fresh.items.length]]) {
      compareGap(oldStart,a,newStart,b);
      oldStart=a+1;newStart=b+1;
    }
  };
  compareChildren(previous,next,0,0);
  const transaction=view.state.tr;
  // All ranges refer to the original documents; changing from the end keeps
  // those offsets valid while each step maps the existing selection normally.
  for(const edit of edits.reverse())transaction.replace(edit.from,edit.to,next.slice(edit.insertFrom,edit.insertTo));
  for(const {node,at} of formats) {
    transaction.removeMark(at,at+node.content.size);
    node.forEach((child,offset)=>{for(const mark of child.marks)transaction.addMark(at+offset,at+offset+child.nodeSize,mark);});
  }
  if(!transaction.doc.eq(next))throw new Error('排版内容更新未完成，完整内容仍保留在源码中。');
  // Remote changes must not become a user's undo step. No view.focus(), state
  // recreation, global selection reset, or scrollIntoView belongs here.
  view.dispatch(transaction.setMeta('addToHistory',false));
}
