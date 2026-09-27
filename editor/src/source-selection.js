// Textarea offsets use UTF-16 code units, just like String.slice. Match whole
// unchanged lines first so two remote edits cannot swallow the cursor's intact
// paragraph into one large replacement, then refine each changed gap by chars.
export function matchingSegments(before, after) {
  const rows=before.length+1, columns=after.length+1;
  if(rows*columns<=500000) {
    const table=new Uint32Array(rows*columns), matches=[];
    for(let a=before.length-1;a>=0;a--) for(let b=after.length-1;b>=0;b--)
      table[a*columns+b]=before[a]===after[b] ? 1+table[(a+1)*columns+b+1]
        : Math.max(table[(a+1)*columns+b],table[a*columns+b+1]);
    for(let a=0,b=0;a<before.length && b<after.length;) {
      if(before[a]===after[b]) { matches.push([a++,b++]); }
      else if(table[(a+1)*columns+b]>=table[a*columns+b+1]) a++; else b++;
    }
    return matches;
  }
  // Bound memory for large notes. Unique unchanged lines form order-preserving
  // anchors (longest increasing subsequence); ambiguous gaps remain local edits.
  const unique=lines=>{
    const values=new Map();
    lines.forEach((line,index)=>values.set(line,values.has(line)?-1:index));
    return values;
  };
  const oldIndex=unique(before),newIndex=unique(after),candidates=[];
  before.forEach((line,a)=>{const b=newIndex.get(line);if(oldIndex.get(line)===a && b>=0)candidates.push([a,b]);});
  const tails=[],previous=new Int32Array(candidates.length).fill(-1);
  candidates.forEach((pair,index)=>{
    let low=0,high=tails.length;
    while(low<high) {const mid=(low+high)>>1;if(candidates[tails[mid]][1]<pair[1])low=mid+1;else high=mid;}
    if(low>0)previous[index]=tails[low-1];tails[low]=index;
  });
  const matches=[];
  for(let index=tails.at(-1);index!==undefined && index>=0;index=previous[index])matches.push(candidates[index]);
  return matches.reverse();
}

export function textReplacements(before,after) {
  const lines=value=>value.match(/[^\n]*\n|[^\n]+$/g)||[];
  const oldLines=lines(before),newLines=lines(after);
  const offsets=values=>{const result=[0];for(const line of values)result.push(result.at(-1)+line.length);return result;};
  const oldOffsets=offsets(oldLines),newOffsets=offsets(newLines),edits=[];
  const appendGap=(from,to,insertFrom,insertTo)=>{
    while(from<to && insertFrom<insertTo && before[from]===after[insertFrom]) {from++;insertFrom++;}
    while(to>from && insertTo>insertFrom && before[to-1]===after[insertTo-1]) {to--;insertTo--;}
    if(from===to && insertFrom===insertTo)return;
    const oldSize=to-from,newSize=insertTo-insertFrom;
    if(oldSize && newSize && (oldSize+1)*(newSize+1)<=500000) {
      // A single line can itself have separate edits around an intact caret.
      // Refine only this bounded gap, using UTF-16 units to match textarea APIs.
      const matches=matchingSegments(before.slice(from,to).split(''),after.slice(insertFrom,insertTo).split(''));
      let aStart=0,bStart=0;
      for(const [a,b] of [...matches,[oldSize,newSize]]) {
        if(a!==aStart || b!==bStart)edits.push({from:from+aStart,to:from+a,size:b-bStart,insertFrom:insertFrom+bStart,insertTo:insertFrom+b});
        aStart=a+1;bStart=b+1;
      }
    } else edits.push({from,to,size:newSize,insertFrom,insertTo});
  };
  let oldStart=0,newStart=0;
  for(const [a,b] of [...matchingSegments(oldLines,newLines),[oldLines.length,newLines.length]]) {
    appendGap(oldOffsets[oldStart],oldOffsets[a],newOffsets[newStart],newOffsets[b]);
    oldStart=a+1;newStart=b+1;
  }
  return edits;
}

export function updateSourceValue(source,value) {
  const before=source.value;
  if(before===value)return;
  const start=source.selectionStart,end=source.selectionEnd,direction=source.selectionDirection;
  const top=source.scrollTop,left=source.scrollLeft,edits=textReplacements(before,value);
  const map=position=>{
    let shift=0;
    for(const edit of edits) {
      if(position<edit.from)break;
      if(position<edit.to)return edit.from+shift+Math.min(position-edit.from,edit.size);
      shift+=edit.size-(edit.to-edit.from);
    }
    return position+shift;
  };
  source.value=value;
  source.setSelectionRange(map(start),map(end),direction);
  source.scrollTop=top;source.scrollLeft=left;
}
