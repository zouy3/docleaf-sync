import {canonicalText,positionQuote,type ReadingCursor} from "./client";
function textNodes(paragraph:HTMLElement){
  const walker=document.createTreeWalker(paragraph,NodeFilter.SHOW_TEXT);
  const nodes:Text[]=[];let node;
  while((node=walker.nextNode()))if(!(node.parentElement?.closest("button,.paragraph-comment-anchor")))nodes.push(node as Text);
  return nodes;
}
function pointAt(nodes:Text[],offset:number){
  for(const node of nodes){if(offset<=node.length)return {node,offset};offset-=node.length;}
  const node=nodes.at(-1);return node?{node,offset:node.length}:null;
}
export function captureCursor(section:HTMLElement,top:number,chapter:{id:string;title:string},index:number):ReadingCursor|null{
  const paragraphs=[...section.querySelectorAll<HTMLElement>("p[data-reader-block]")];
  const paragraph=paragraphs.filter(p=>p.getBoundingClientRect().top<=top).at(-1)||paragraphs[0];
  if(!paragraph)return null;
  const nodes=textNodes(paragraph),raw=nodes.map(n=>n.data).join("");
  if(!nodes.length)return null;
  let low=0,high=Math.max(0,raw.length-1);
  while(low<high){
    const mid=Math.floor((low+high)/2),point=pointAt(nodes,mid)!;
    const range=document.createRange();range.setStart(point.node,point.offset);
    range.setEnd(point.node,Math.min(point.node.length,point.offset+1));
    if(range.getBoundingClientRect().bottom<top)low=mid+1;else high=mid;
  }
  const offset=canonicalText(raw.slice(0,low)).length;
  return {version:1,chapter_id:chapter.id,chapter_index:index,chapter_title:chapter.title,paragraph_id:paragraph.getAttribute("idx"),ordinal:paragraphs.indexOf(paragraph),character_offset:offset,quote:positionQuote(canonicalText(raw),offset)};
}
export function restoreCursor(canvas:HTMLElement,section:HTMLElement,cursor:ReadingCursor){
  const paragraphs=[...section.querySelectorAll<HTMLElement>("p[data-reader-block]")];
  const quoted=cursor.quote?paragraphs.find(p=>canonicalText(textNodes(p).map(n=>n.data).join("")).includes(cursor.quote)):undefined;
  const paragraph=paragraphs.find(p=>cursor.paragraph_id!==null&&p.getAttribute("idx")===cursor.paragraph_id)||quoted||paragraphs[cursor.ordinal];
  if(!paragraph)return false;
  const nodes=textNodes(paragraph),raw=nodes.map(n=>n.data).join("");
  const normalized=canonicalText(raw);
  const found=cursor.quote?normalized.indexOf(cursor.quote):-1;
  const desired=found>=0?found:Math.min(cursor.character_offset,normalized.length);
  let offset=0,count=0;
  while(offset<raw.length&&count<desired){if(canonicalText(raw[offset]))count++;offset++;}
  const point=pointAt(nodes,Math.min(offset,Math.max(0,raw.length-1)));
  const range=document.createRange();
  if(point){range.setStart(point.node,point.offset);range.setEnd(point.node,Math.min(point.node.length,point.offset+1));}
  const rect=point?range.getBoundingClientRect():paragraph.getBoundingClientRect();
  canvas.scrollTop+=rect.top-canvas.getBoundingClientRect().top-24;
  return true;
}
