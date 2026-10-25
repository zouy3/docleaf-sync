"use client";

import { memo, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, MouseEvent, SyntheticEvent } from "react";
import { marked } from "marked";
import {readingSync,type CloudBook,type ReadingCursor} from "./sync/client";
import {captureCursor,restoreCursor} from "./sync/position";
import {AccountPanel} from "./sync/AccountPanel";

type Book = {
  id: string;
  name: string;
  type: string;
  size: number;
  updatedAt: number;
  content?: string;
  buffer?: ArrayBuffer;
  sourceBookId?: string;
  author?: string;
  chapters?: RemoteChapter[];
  comments?: ReaderComment[];
};

type TocItem = { label: string; target: string; level: number };
type OnlineBook = { id: string; title: string; author: string; description?: string };
type RankTab = { name: string; algo: number };
type RecommendedBook = OnlineBook & { cover?: string; category?: string; rank: number; readCount?: string };
type ReaderComment = { id: string; author: string; content: string; likes?: number; images?: string[] };
type RemoteChapter = { id: string; title: string; version?: string; content?: string; comments?: ReaderComment[]; paragraphComments?: Record<string, ReaderComment[]>; paragraphCommentCounts?: Record<string, number>; commentsVersion?: number; cachedAt?: number };

const DB = "docleaf-library";
const STORE = "books";
const ACCEPT = ".txt,.md,.markdown,.html,.htm,.fb2,.rtf,.docx,.epub,.pdf";
const SOURCE_API = "http://127.0.0.1:8787";

function proxiedCommentImage(url: string) {
  return `${SOURCE_API}/image?url=${encodeURIComponent(url)}`;
}

function retryOriginalCommentImage(image: HTMLImageElement) {
  if (image.dataset.originalRetried === "true") return false;
  try {
    const current = new URL(image.src);
    if (current.origin !== SOURCE_API || current.pathname !== "/image") return false;
    const original = current.searchParams.get("url");
    if (!original) return false;
    image.dataset.originalRetried = "true";
    image.referrerPolicy = "no-referrer";
    image.src = original;
    return true;
  } catch {
    return false;
  }
}

function findRankCard(value: any, depth = 0): any {
  if (!value || depth > 12) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findRankCard(item, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (typeof value !== "object") return null;
  if (value.rank_with_category_data) return value;
  for (const item of Object.values(value)) {
    const found = findRankCard(item, depth + 1);
    if (found) return found;
  }
  return null;
}

function parseRankBooks(payload: any): RecommendedBook[] {
  const cells = payload?.data?.cell_view?.cell_data;
  if (!Array.isArray(cells)) return [];
  const books: RecommendedBook[] = [];
  const seen = new Set<string>();
  const visit = (value: any) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) return value.forEach(visit);
    const raw = Array.isArray(value.book_data) ? value.book_data[0] : value.book_data;
    if (raw && typeof raw === "object") {
      const id = String(raw.book_id || "");
      if (id && !seen.has(id)) {
        seen.add(id);
        books.push({ id, title: String(raw.book_name || "未命名作品"), author: String(raw.author || "未知作者"), description: String(raw.abstract || raw.book_abstract_v2 || ""), cover: String(raw.thumb_url || raw.detail_page_thumb_url || ""), category: String(raw.category || "").split(/[,，]/)[0], rank: books.length + 1, readCount: String(raw.read_cnt_text || raw.rank_score || "") });
      }
    }
    Object.values(value).forEach(visit);
  };
  cells.forEach(visit);
  return books;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: "id" });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function dbAll(): Promise<Book[]> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(STORE).objectStore(STORE).getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function dbGet(id: string): Promise<Book | undefined> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(STORE).objectStore(STORE).get(id);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function dbPut(book: Book) {
  const db = await openDb();
  return new Promise<void>((resolve, reject) => {
    const req = db.transaction(STORE, "readwrite").objectStore(STORE).put(book);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

async function dbDelete(id: string) {
  const db = await openDb();
  return new Promise<void>((resolve, reject) => {
    const req = db.transaction(STORE, "readwrite").objectStore(STORE).delete(id);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

// Merge changes inside one transaction so background chapter caching cannot
// overwrite a paragraph comment saved by a foreground request.
async function dbUpdate(id: string, fallback: Book, update: (book: Book) => Book): Promise<Book> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, "readwrite");
    const store = transaction.objectStore(STORE);
    const request = store.get(id);
    let result: Book;
    request.onsuccess = () => {
      result = update(request.result || fallback);
      store.put(result);
    };
    transaction.oncomplete = () => resolve(result!);
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

function safeHtml(raw: string) {
  const doc = new DOMParser().parseFromString(raw, "text/html");
  doc.querySelectorAll("script,style,iframe,object,embed,form").forEach((node) => node.remove());
  doc.querySelectorAll("*").forEach((node) => {
    [...node.attributes].forEach((attr) => {
      if (attr.name.startsWith("on") || ["src", "href"].includes(attr.name)) node.removeAttribute(attr.name);
    });
  });
  return doc.body.innerHTML;
}

function textToHtml(text: string) {
  const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return escaped
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => `<p>${line}</p>`)
    .join("");
}

function formatSize(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

function prepareContent(raw: string) {
  const doc = new DOMParser().parseFromString(raw, "text/html");
  const chapterPattern = /^(?:正文[\s　]*)?(?:第[\s　]*[零〇一二三四五六七八九十百千万两0-9０-９]+[\s　]*[章节卷回部篇集幕]|[上中下终]卷|序章|序言|楔子|引子|前言|后记|尾声|番外(?:篇)?)(?:[\s　]*[：:、.．-]?[\s　]*.*)?$/;
  [...doc.body.querySelectorAll("p")].forEach((node) => {
    if (!node.querySelector("br")) return;
    const pieces = node.innerHTML.split(/<br\s*\/?\s*>/i).map((line) => line.trim()).filter(Boolean);
    if (!pieces.some((line) => {
      const probe = doc.createElement("div");
      probe.innerHTML = line;
      return chapterPattern.test(probe.textContent?.trim() || "");
    })) return;
    const fragment = doc.createDocumentFragment();
    pieces.forEach((line) => {
      const probe = doc.createElement("div");
      probe.innerHTML = line;
      const element = doc.createElement(chapterPattern.test(probe.textContent?.trim() || "") ? "h2" : "p");
      element.innerHTML = line;
      fragment.appendChild(element);
    });
    node.replaceWith(fragment);
  });
  let headings = [...doc.body.querySelectorAll("h1,h2,h3,h4")];
  if (headings.length < 2) {
    [...doc.body.querySelectorAll("p")].forEach((node) => {
      const label = node.textContent?.trim() || "";
      if (label.length <= 60 && chapterPattern.test(label)) {
        const heading = doc.createElement("h2");
        heading.innerHTML = node.innerHTML;
        node.replaceWith(heading);
      }
    });
    headings = [...doc.body.querySelectorAll("h1,h2,h3,h4")];
  }
  const toc = headings.map((node, index) => {
    const id = `chapter-${index + 1}`;
    node.id = id;
    return { label: node.textContent?.trim() || `章节 ${index + 1}`, target: id, level: Number(node.tagName.slice(1)) };
  });
  [...doc.body.querySelectorAll("h1,h2,h3,h4,p,blockquote,li")].forEach((node, index) => {
    node.setAttribute("data-reader-block", String(index));
  });
  return { html: doc.body.innerHTML, toc };
}

function normalizeComments(payload: any): ReaderComment[] {
  const comments: ReaderComment[] = [];
  const seen = new Set<string>();
  const visit = (value: any) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) return value.forEach(visit);
    const id = String(value.comment_id || value.commentId || value.id || "");
    const content = value.common?.content?.text || value.content || value.comment_content || value.text || value.comment_text;
    if (id && typeof content === "string" && content.trim() && content.length < 3000 && !seen.has(id)) {
      seen.add(id);
      comments.push({
        id,
        author: value.common?.user_info?.base_info?.user_name || value.user_info?.name || value.user?.name || value.user_name || value.nickname || "番茄读者",
        content: content.replace(/<[^>]+>/g, "").trim(),
        likes: Number(value.stat?.digg_count || value.digg_count || value.like_count || value.likes || 0),
      });
    }
    Object.values(value).forEach(visit);
  };
  visit(payload?.data || payload);
  return comments.slice(0, 50);
}

function normalizeParagraphCommentPage(payload: any): ReaderComment[] {
  const code = Number(payload?.code ?? 0);
  if (code !== 0 && code !== 200) return [];
  const list = payload?.data?.data_list;
  if (!Array.isArray(list)) return [];
  return list.flatMap((entry: any) => {
    const comment = entry?.comment;
    if (!comment || typeof comment !== "object") return [];
    const common = comment.common || {};
    const content = common.content || {};
    const rawImages = content?.image_data_list?.image_data;
    const imageEntries = Array.isArray(rawImages) ? rawImages : (rawImages && typeof rawImages === "object" ? [rawImages] : []);
    const images = [...new Set(imageEntries.flatMap((image: any) => {
      const values = typeof image === "string"
        ? [image]
        : [image?.web_url, image?.expand_web_url, image?.url, image?.image_url, ...(Array.isArray(image?.url_list) ? image.url_list.map((item: any) => typeof item === "string" ? item : item?.url) : [])];
      const url = values.map((value) => String(value || "").trim()).find((value) => /^https?:\/\/[^/]+/.test(value));
      return url ? [url] : [];
    }))];
    const text = String(content.text || "").trim();
    if (!text && !images.length) return [];
    return [{
      id: String(comment.comment_id || crypto.randomUUID()),
      author: String(common?.user_info?.base_info?.user_name || "番茄读者"),
      content: text,
      likes: Number(comment?.stat?.digg_count || entry?.stat?.digg_count || 0),
      images,
    }];
  });
}

function collectCommentIds(payload: any) {
  const ids = new Set<string>();
  const visit = (value: any, key = "") => {
    if (value == null) return;
    if (Array.isArray(value)) return value.forEach((item) => visit(item, key));
    if (typeof value === "object") return Object.entries(value).forEach(([nextKey, item]) => visit(item, nextKey));
    if (/comment.*id|insert.*id/i.test(key)) String(value).split(",").forEach((id) => /^\d+$/.test(id.trim()) && ids.add(id.trim()));
  };
  visit(payload);
  return [...ids].slice(0, 50);
}

function collectParagraphCommentRefs(payload: any) {
  const refs: Record<string, string[]> = {};
  const direct: Record<string, ReaderComment[]> = {};
  const counts: Record<string, number> = {};
  const indexed = payload?.data?.data;
  if (indexed && typeof indexed === "object" && !Array.isArray(indexed)) {
    Object.entries(indexed).forEach(([index, value]: [string, any]) => {
      if (!/^\d+$/.test(index) || !value || typeof value !== "object") return;
      counts[index] = Number(value.count || 0);
      refs[index] = collectCommentIds(value);
      const comments = normalizeComments(value);
      if (comments.length) direct[index] = comments;
    });
  }
  const visit = (value: any) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) return value.forEach(visit);
    const rawIndex = value.para_index ?? value.paragraph_index ?? value.paragraphIndex;
    if (rawIndex !== undefined && /^\d+$/.test(String(rawIndex))) {
      const key = String(rawIndex);
      refs[key] = [...new Set([...(refs[key] || []), ...collectCommentIds(value)])];
      counts[key] = Math.max(counts[key] || 0, Number(value.count || 0));
      const comments = normalizeComments(value);
      if (comments.length) direct[key] = comments;
    }
    Object.values(value).forEach(visit);
  };
  visit(payload?.data || payload);
  return { refs, direct, counts };
}

function escapeText(value: string) {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function normalizeRemoteContent(title: string, content: string) {
  const doc = new DOMParser().parseFromString(content, "text/html");
  // Some sources return newline-delimited plain text, others return indexed
  // HTML paragraphs. Preserve source indexes whenever they are supplied.
  doc.querySelectorAll("br").forEach((node) => node.replaceWith(doc.createTextNode("\n")));
  if (!doc.body.querySelector("p,h1,h2,h3,h4,li,blockquote")) {
    doc.body.innerHTML = textToHtml(doc.body.textContent || "");
  } else {
    [...doc.body.querySelectorAll("p")].forEach((paragraph) => {
      if (paragraph.hasAttribute("idx") || paragraph.children.length) return;
      const lines = (paragraph.textContent || "").split(/\r?\n/).map(line => line.trim()).filter(Boolean);
      if (lines.length < 2) return;
      const fragment = doc.createDocumentFragment();
      lines.forEach((line) => {
        const block = doc.createElement("p");
        block.textContent = line;
        fragment.append(block);
      });
      paragraph.replaceWith(fragment);
    });
  }
  const normalizedTitle = title.replace(/[\s　]+/g, "");
  const firstBlock = doc.body.querySelector("p,h1,h2,h3,h4");
  if (firstBlock?.textContent?.replace(/[\s　]+/g, "") === normalizedTitle) firstBlock.remove();
  // Source text often already has full-width indentation. The reading setting
  // supplies exactly two characters, rather than adding to existing spaces.
  doc.body.querySelectorAll("p").forEach((paragraph) => {
    const firstText = paragraph.firstChild;
    if (firstText?.nodeType === 3) firstText.textContent = firstText.textContent?.replace(/^[\s　]+/, "") || "";
  });
  return safeHtml(doc.body.innerHTML);
}

function decorateRemoteContent(title: string, content: string, paragraphComments: Record<string, ReaderComment[]> = {}, paragraphCommentCounts: Record<string, number> = {}, chapterComments: ReaderComment[] = []) {
  const prepared = prepareContent(`<h2>${escapeText(title)}</h2>${normalizeRemoteContent(title, content)}`);
  const doc = new DOMParser().parseFromString(prepared.html, "text/html");
  const zeroBased = Object.prototype.hasOwnProperty.call(paragraphCommentCounts, "0") || Object.prototype.hasOwnProperty.call(paragraphComments, "0");
  const paragraphs = [...doc.body.querySelectorAll("p")];
  const hasSourceIndexes = paragraphs.some((paragraph) => paragraph.hasAttribute("idx"));
  let fallbackIndex = 0;
  paragraphs.forEach((paragraph) => {
    if (hasSourceIndexes && !paragraph.hasAttribute("idx")) return;
    const paraIndex = paragraph.getAttribute("idx") || String(zeroBased ? fallbackIndex : fallbackIndex + 1);
    fallbackIndex++;
    const comments = paragraphComments[paraIndex] || [];
    const count = paragraphCommentCounts[paraIndex] || comments.length;
    if (!count) return;
    const button = doc.createElement("button");
    button.type = "button";
    button.className = "paragraph-comment-toggle";
    button.setAttribute("data-paragraph-comments", paraIndex);
    button.setAttribute("data-comment-count", String(count));
    button.textContent = `评论 ${count}`;
    const panel = doc.createElement("aside");
    panel.className = "paragraph-comment-panel";
    panel.setAttribute("data-loaded", comments.length ? "true" : "false");
    panel.innerHTML = comments.map((comment) => `<article><b>${escapeText(comment.author)}</b>${comment.content ? `<p>${escapeText(comment.content)}</p>` : ""}${comment.images?.map((url) => `<img src="${escapeText(proxiedCommentImage(url))}" alt="评论图片" loading="lazy" referrerpolicy="no-referrer">`).join("") || ""}${comment.likes ? `<small>赞 ${comment.likes}</small>` : ""}</article>`).join("");
    paragraph.insertAdjacentElement("afterend", panel);
    const anchor = doc.createElement("span");
    anchor.className = "paragraph-comment-anchor";
    anchor.append(button);
    paragraph.append(anchor);
  });
  return doc.body.innerHTML + (chapterComments.length ? `<details class="chapter-discussion"><summary>本章评论 · ${chapterComments.length}</summary><section class="reader-comments">${chapterComments.map(comment => `<article><b>${escapeText(comment.author)}</b><p>${escapeText(comment.content)}</p>${comment.images?.map(url => `<img src="${escapeText(proxiedCommentImage(url))}" alt="评论图片" loading="lazy" referrerpolicy="no-referrer">`).join("") || ""}${comment.likes ? `<small>赞 ${comment.likes}</small>` : ""}</article>`).join("")}</section></details>` : "");
}

function flattenEpubToc(items: any[], level = 1): TocItem[] {
  return items.flatMap((item) => [
    { label: item.label?.trim() || "未命名章节", target: item.href, level },
    ...flattenEpubToc(item.subitems || [], Math.min(level + 1, 4)),
  ]);
}

// Paragraph discussions are expanded and populated in this DOM subtree.
// Unrelated parent updates (cache counters, scroll progress, appearance) must
// never re-apply its initial HTML and discard the live discussion panels.
const ChapterBody = memo(function ChapterBody({ html }: { html: string }) {
  return <div className="chapter-body" dangerouslySetInnerHTML={{ __html: html }} />;
});

export default function Home() {
  const [syncOpen,setSyncOpen]=useState(false);
  const [,setSyncRevision]=useState(0);
  const [dismissedCloudRevision,setDismissedCloudRevision]=useState("");
  const cloudCursorRef=useRef<ReadingCursor|null>(null);
  const syncCursorSignatureRef=useRef("");
  const [books, setBooks] = useState<Book[]>([]);
  const [active, setActive] = useState<Book | null>(null);
  const [fontSize, setFontSize] = useState(18);
  const [lineHeight, setLineHeight] = useState(1.85);
  const [font, setFont] = useState("serif");
  const [paperWidth, setPaperWidth] = useState(790);
  const [fitWidth, setFitWidth] = useState(false);
  const [availablePaperWidth, setAvailablePaperWidth] = useState(3200);
  const [firstIndent, setFirstIndent] = useState(true);
  const [darkMode, setDarkMode] = useState(false);
  const [sideOpen, setSideOpen] = useState(true);
  const [zen, setZen] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [toast, setToast] = useState("");
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState("");
  const [pdfUrl, setPdfUrl] = useState<string | null>(null);
  const [toc, setToc] = useState<TocItem[]>([]);
  const [sideTab, setSideTab] = useState<"library" | "toc">("library");
  const [progress, setProgress] = useState(0);
  const [currentChapter, setCurrentChapter] = useState("");
  const [sourceOpen, setSourceOpen] = useState(false);
  const [sourceResults, setSourceResults] = useState<OnlineBook[]>([]);
  const [sourceState, setSourceState] = useState("输入书名或作品 ID");
  const [sourceBusy, setSourceBusy] = useState(false);
  const [sourceProgress, setSourceProgress] = useState(0);
  const [remoteChapterIndex, setRemoteChapterIndex] = useState(0);
  const [remoteContent, setRemoteContent] = useState("");
  const [continuous, setContinuous] = useState(true);
  const [readingChapters, setReadingChapters] = useState<{index:number; html:string}[]>([]);
  const [appendLoading, setAppendLoading] = useState(false);
  const [appendError, setAppendError] = useState("");
  const appendingRef = useRef(false);
  const prefetchRef = useRef<{key:string; promise:Promise<unknown>} | null>(null);
  const [remoteComments, setRemoteComments] = useState<ReaderComment[]>([]);
  const [remoteLoading, setRemoteLoading] = useState(false);
  const [cacheRunning, setCacheRunning] = useState(false);
  const [cacheState, setCacheState] = useState("");
  const [recommendOpen, setRecommendOpen] = useState(false);
  const [recommendBusy, setRecommendBusy] = useState(false);
  const [recommendError, setRecommendError] = useState("");
  const [rankId, setRankId] = useState("");
  const [rankTabs, setRankTabs] = useState<RankTab[]>([]);
  const [rankAlgo, setRankAlgo] = useState(101);
  const [recommendations, setRecommendations] = useState<RecommendedBook[]>([]);
  const [selectedRecommendation, setSelectedRecommendation] = useState<RecommendedBook | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const canvasRef = useRef<HTMLElement>(null);
  const epubRef = useRef<HTMLDivElement>(null);
  const renditionRef = useRef<any>(null);
  const epubBookRef = useRef<any>(null);
  const tocRef = useRef<TocItem[]>([]);
  const currentTocRef = useRef<HTMLButtonElement>(null);
  const objectUrlRef = useRef<string | null>(null);
  const sourceInputRef = useRef<HTMLInputElement>(null);
  const cacheRunRef = useRef<string | null>(null);
  const remoteLoadRef = useRef(0);
  const restoringRef = useRef(false);
  const pendingRestoreRef = useRef<{ id: string; progress: number } | null>(null);
  const commentRequestsRef = useRef(0);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const measure = () => {
      const style = getComputedStyle(canvas);
      setAvailablePaperWidth(Math.max(280, Math.floor(canvas.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight))));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(canvas);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    readingSync.init();
    const unsubscribe=readingSync.subscribe(()=>setSyncRevision(n=>n+1));
    void readingSync.sync();
    const interval=window.setInterval(()=>{if(!document.hidden)void readingSync.sync();},20000);
    const reconnect=()=>void readingSync.sync();
    window.addEventListener("online",reconnect);
    window.addEventListener("focus",reconnect);
    return ()=>{unsubscribe();clearInterval(interval);window.removeEventListener("online",reconnect);window.removeEventListener("focus",reconnect);};
  },[]);

  async function openCloudBook(row:CloudBook){
    let book=await dbGet("fanqie-"+row.book_id);
    if(!book){
      const response=await fetch(`${SOURCE_API}/api/v1/books/${row.book_id}/directory`,{signal:AbortSignal.timeout(20000)});
      const payload=await response.json();
      const chapters=(payload?.data?.item_data_list||[]).map((item:any)=>({id:String(item.item_id||item.itemId||""),title:item.title||"未命名章节",version:String(item.version||"")})).filter((item:any)=>item.id);
      if(!response.ok||!chapters.length)throw Error("目录暂时无法获取，请确认本地番茄服务已启动");
      book={id:"fanqie-"+row.book_id,name:row.title,author:row.author,type:"fanqie",sourceBookId:row.book_id,chapters,size:0,updatedAt:Date.now()};
      await dbPut(book);
      setBooks(old=>[book!,...old.filter(item=>item.id!==book!.id)]);
    }
    if(row.cursor){
      const index=book.chapters?.findIndex(chapter=>chapter.id===row.cursor!.chapter_id)??-1;
      if(index<0)throw Error("云端章节已不在本机目录中，请刷新目录后重试");
      readingSync.acceptRemote(row);
      cloudCursorRef.current=row.cursor;
      localStorage.setItem("docleaf-chapter:"+book.id,String(index));
    }
    if(active?.id===book.id)await loadRemoteChapter(book,Number(localStorage.getItem("docleaf-chapter:"+book.id)||0));
    else setActive(book);
  }

  function uploadShelf(){
    for(const book of books)if(book.type==="fanqie"&&book.sourceBookId&&!readingSync.rows.some(row=>row.book_id===book.sourceBookId)){
      readingSync.queue({book_id:book.sourceBookId,title:book.name,author:book.author||"",cover:""},null);
    }
    void readingSync.sync();
  }

  useEffect(() => {
    dbAll().then((items) => {
      const sorted = items.sort((a, b) => b.updatedAt - a.updatedAt);
      setBooks(sorted);
      const lastId = localStorage.getItem("docleaf-last-book");
      const lastBook = sorted.find((book) => book.id === lastId);
      if (lastBook) setActive(lastBook);
    });
    const prefs = localStorage.getItem("docleaf-prefs");
    if (prefs) {
      const p = JSON.parse(prefs);
      setFontSize(p.fontSize || 18);
      setLineHeight(p.lineHeight || 1.85);
      setFont(p.font || "serif");
      setPaperWidth(p.paperWidth || 790);
      setFitWidth(Boolean(p.fitWidth));
      setFirstIndent(p.firstIndent !== false);
      setDarkMode(Boolean(p.darkMode));
      setContinuous(p.continuous !== false);
    }
  }, []);

  useEffect(() => {
    if (active) localStorage.setItem("docleaf-last-book", active.id);
  }, [active]);

  useEffect(() => {
    localStorage.setItem("docleaf-prefs", JSON.stringify({ fontSize, lineHeight, font, paperWidth, fitWidth, firstIndent, darkMode, continuous }));
  }, [fontSize, lineHeight, font, paperWidth, fitWidth, firstIndent, darkMode, continuous]);

  useEffect(() => {
    if (objectUrlRef.current) URL.revokeObjectURL(objectUrlRef.current);
    objectUrlRef.current = null;
    setPdfUrl(null);
    renditionRef.current?.destroy?.();
    renditionRef.current = null;
    epubBookRef.current?.destroy?.();
    epubBookRef.current = null;
    tocRef.current = [];
    setToc([]);
    setCurrentChapter("");
    setProgress(Number(localStorage.getItem(`docleaf-progress:${active?.id}`) || 0));
    if (active?.type === "fanqie" && active.chapters?.length) {
      const items = active.chapters.map((chapter, index) => ({ label: chapter.title, target: `remote:${index}`, level: 2 }));
      tocRef.current = items;
      setToc(items);
      const savedIndex = Math.max(0, Math.min(active.chapters.length - 1, Number(localStorage.getItem(`docleaf-chapter:${active.id}`) || 0)));
      void loadRemoteChapter(active, savedIndex);
      return;
    }
    if (!active?.buffer) return;
    if (active.type === "pdf") {
      objectUrlRef.current = URL.createObjectURL(new Blob([active.buffer], { type: "application/pdf" }));
      setPdfUrl(objectUrlRef.current);
    }
    if (active.type === "epub" && epubRef.current) {
      import("epubjs").then(({ default: ePub }) => {
        if (!epubRef.current) return;
        const book = ePub(active.buffer!);
        epubBookRef.current = book;
        const rendition = book.renderTo(epubRef.current, { width: "100%", height: "100%", spread: "none" });
        renditionRef.current = rendition;
        rendition.themes.default({ body: { padding: "28px 46px !important", color: darkMode ? "#d7dce5 !important" : "#292929 !important", background: darkMode ? "#252a33 !important" : "#ffffff !important", "font-family": font, "font-size": `${fontSize}px`, "line-height": String(lineHeight) } });
        Promise.all([book.loaded.navigation, book.ready.then(() => book.locations.generate(900))]).then(([navigation]) => {
          const items = flattenEpubToc(navigation.toc || []);
          tocRef.current = items;
          setToc(items);
          rendition.display(localStorage.getItem(`docleaf-cfi:${active.id}`) || undefined);
        });
        rendition.on("relocated", (location: any) => {
          const pct = Math.round((location.start.percentage || 0) * 100);
          setProgress(pct);
          localStorage.setItem(`docleaf-progress:${active.id}`, String(pct));
          localStorage.setItem(`docleaf-cfi:${active.id}`, location.start.cfi);
          const href = location.start.href?.split("#")[0];
          const chapter = tocRef.current.find((item) => item.target.split("#")[0] === href);
          if (chapter) setCurrentChapter(chapter.label);
        });
      });
    }
  }, [active?.id]);

  useEffect(() => {
    renditionRef.current?.themes?.default({ body: {
      color: darkMode ? "#d7dce5 !important" : "#292929 !important",
      background: darkMode ? "#252a33 !important" : "#ffffff !important",
      "font-family": font, "font-size": `${fontSize}px`, "line-height": String(lineHeight),
      padding: "28px 46px !important",
    } });
  }, [darkMode, font, fontSize, lineHeight, active?.id]);

  const prepared = useMemo(() => active?.content ? prepareContent(active.content) : { html: "", toc: [] as TocItem[] }, [active]);

  useEffect(() => {
    if (!active?.content) return;
    tocRef.current = prepared.toc;
    setToc(prepared.toc);
    const saved = Number(localStorage.getItem(`docleaf-progress:${active.id}`) || 0);
    setProgress(saved);
    window.setTimeout(() => restoreScrollAnchor(active.id, saved), 0);
  }, [active, prepared]);

  useEffect(() => {
    if (!active || active.type === "epub" || active.type === "pdf") return;
    const anchorId = active.type === "fanqie" ? `${active.id}:${remoteChapterIndex}` : active.id;
    window.setTimeout(() => restoreScrollAnchor(anchorId, progress), 0);
  }, [fontSize, lineHeight, paperWidth, fitWidth, firstIndent, font, sideOpen, zen]);

  useEffect(() => {
    if (remoteLoading || !remoteContent || !pendingRestoreRef.current) return;
    const saved = pendingRestoreRef.current;
    pendingRestoreRef.current = null;
    const frame = requestAnimationFrame(() => restoreScrollAnchor(saved.id, saved.progress));
    return () => cancelAnimationFrame(frame);
  }, [remoteLoading, remoteContent]);

  useEffect(() => {
    const save = () => {
      if (document.visibilityState === "hidden") trackScroll();
    };
    const resize = () => {
      if (!active || remoteLoading || active.type === "pdf" || active.type === "epub") return;
      restoreScrollAnchor(active.type === "fanqie" ? `${active.id}:${remoteChapterIndex}` : active.id, progress);
    };
    document.addEventListener("visibilitychange", save);
    window.addEventListener("pagehide", trackScroll);
    window.addEventListener("resize", resize);
    return () => {
      document.removeEventListener("visibilitychange", save);
      window.removeEventListener("pagehide", trackScroll);
      window.removeEventListener("resize", resize);
    };
  });

  useEffect(() => {
    if (sideOpen && sideTab === "toc" && currentChapter) {
      window.setTimeout(() => currentTocRef.current?.scrollIntoView({ behavior: "smooth", block: "center" }), 0);
    }
  }, [sideOpen, sideTab, currentChapter]);

  function trackScroll() {
    if (restoringRef.current || remoteLoading) return;
    if (!active || active.type === "epub" || active.type === "pdf") return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const max = canvas.scrollHeight - canvas.clientHeight;
    const readingTop = canvas.getBoundingClientRect().top + 24;
    const sections = [...canvas.querySelectorAll<HTMLElement>("[data-reading-chapter]")];
    const section = sections.filter(node => node.getBoundingClientRect().top <= readingTop).at(-1) || sections[0];
    const index = section ? Number(section.dataset.readingChapter) : remoteChapterIndex;
    const within = section ? Math.max(0, Math.min(1, (readingTop - section.getBoundingClientRect().top) / Math.max(1,section.offsetHeight))) : (max > 0 ? canvas.scrollTop / max : 0);
    if (active.type === "fanqie") {
      setRemoteChapterIndex(index);
      setCurrentChapter(active.chapters?.[index]?.title || "");
      localStorage.setItem(`docleaf-chapter:${active.id}`, String(index));
      if (continuous && max - canvas.scrollTop < 160 && !appendError) void appendNextChapter();
      else if (continuous && max - canvas.scrollTop < canvas.clientHeight) prefetchNextChapter();
    }
    const pct = active.type === "fanqie" && active.chapters?.length
      ? Math.round(((index + within) / active.chapters.length) * 100)
      : Math.round(within * 100);
    setProgress(pct);
    localStorage.setItem(`docleaf-progress:${active.id}`, String(pct));
    const blocks = [...(section || canvas).querySelectorAll<HTMLElement>("[data-reader-block]")];
    const anchor = blocks.filter((node) => node.getBoundingClientRect().top <= readingTop).at(-1) || blocks[0];
    if(active.type==="fanqie"&&active.sourceBookId&&section&&active.chapters?.[index]){
      const cursor=captureCursor(section,readingTop,active.chapters[index],index);
      const signature=JSON.stringify(cursor);
      if(cursor&&signature!==syncCursorSignatureRef.current){
        syncCursorSignatureRef.current=signature;
        readingSync.queue({book_id:active.sourceBookId,title:active.name,author:active.author||"",cover:""},cursor);
      }
    }
    if (anchor) localStorage.setItem(`docleaf-anchor:${active.id}${active.type === "fanqie" ? `:${index}` : ""}`, JSON.stringify({ block: Number(anchor.dataset.readerBlock || 0), offset: readingTop - anchor.getBoundingClientRect().top, relative: true }));
    const visible = prepared.toc.map((item) => document.getElementById(item.target)).filter(Boolean).reverse().find((node) => (node as HTMLElement).getBoundingClientRect().top < 240);
    if (visible) setCurrentChapter(visible.textContent?.trim() || "");
  }

  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (!active || active.type !== "fanqie" || !continuous || sourceOpen || recommendOpen || event.ctrlKey || event.metaKey || event.altKey) return;
      const target = event.target as HTMLElement;
      if (target.closest("input,textarea,select,[contenteditable=true],.paragraph-comment-panel")) return;
      if (event.key === " " && target.closest("button,summary")) return;
      const down = event.key === "PageDown" || event.key === "ArrowDown" || (event.key === " " && !event.shiftKey);
      const up = event.key === "PageUp" || event.key === "ArrowUp" || (event.key === " " && event.shiftKey);
      const canvas = canvasRef.current;
      if ((!down && !up) || !canvas) return;
      event.preventDefault();
      if (down && canvas.scrollHeight - canvas.clientHeight - canvas.scrollTop < 160) {
        if (!appendError) void appendNextChapter();
      } else canvas.scrollBy({ top: (down ? 1 : -1) * (event.key.startsWith("Arrow") ? 60 : canvas.clientHeight * .85), behavior:"smooth" });
    };
    window.addEventListener("keydown",keydown);
    return () => window.removeEventListener("keydown",keydown);
  });

  function restoreScrollAnchor(bookId: string, fallbackProgress: number) {
    const canvas = canvasRef.current;
    if (!canvas) return;
    restoringRef.current = true;
    requestAnimationFrame(() => { requestAnimationFrame(() => { restoringRef.current = false; }); });
    try {
      const anchor = JSON.parse(localStorage.getItem(`docleaf-anchor:${bookId}`) || "null");
      const index = bookId.split(":").at(-1);
      const section = canvas.querySelector<HTMLElement>(`[data-reading-chapter="${index}"]`) || canvas;
      if(cloudCursorRef.current&&section!==canvas){
        const cursor=cloudCursorRef.current;cloudCursorRef.current=null;
        if(restoreCursor(canvas,section,cursor))return;
      }
      const block = section.querySelector<HTMLElement>(`[data-reader-block="${anchor?.block}"]`);
      if (block) {
        const readingTop = anchor.relative ? canvas.getBoundingClientRect().top + 24 : 240;
        canvas.scrollTop += block.getBoundingClientRect().top - readingTop + Number(anchor.offset || 0);
        return;
      }
    } catch {}
    canvas.scrollTop = (fallbackProgress / 100) * Math.max(0, canvas.scrollHeight - canvas.clientHeight);
  }

  function jumpProgress(value: number) {
    if (!active) return;
    if (active.type === "fanqie" && active.chapters?.length) {
      const index = Math.min(active.chapters.length - 1, Math.floor((value / 100) * active.chapters.length));
      void loadRemoteChapter(active, index);
      return;
    }
    setProgress(value);
    localStorage.setItem(`docleaf-progress:${active.id}`, String(value));
    if (active.type === "epub" && epubBookRef.current?.locations) {
      renditionRef.current?.display(epubBookRef.current.locations.cfiFromPercentage(value / 100));
    } else if (active.type !== "pdf" && canvasRef.current) {
      canvasRef.current.scrollTo({ top: (value / 100) * (canvasRef.current.scrollHeight - canvasRef.current.clientHeight), behavior: "smooth" });
    }
  }

  function jumpToc(item: TocItem) {
    if (active?.type === "fanqie" && item.target.startsWith("remote:")) void loadRemoteChapter(active, Number(item.target.slice(7)));
    else if (active?.type === "epub") renditionRef.current?.display(item.target);
    else document.getElementById(item.target)?.scrollIntoView({ behavior: "smooth", block: "start" });
    setCurrentChapter(item.label);
  }

  async function toggleParagraphComments(event: MouseEvent<HTMLElement>) {
    const button = (event.target as HTMLElement).closest<HTMLButtonElement>(".paragraph-comment-toggle");
    if (!button) return;
    const panel = button.closest("p")?.nextElementSibling as HTMLElement | null;
    const open = button.classList.toggle("open");
    panel?.classList.toggle("open", open);
    button.textContent = open ? "收起评论" : `评论 ${button.dataset.commentCount || 0}`;
    if (!open || !panel || panel.dataset.loaded === "true" || !active?.sourceBookId) return;
    const chapterIndex = Number(button.closest<HTMLElement>("[data-reading-chapter]")?.dataset.readingChapter ?? remoteChapterIndex);
    const chapter = active.chapters?.[chapterIndex];
    const paragraphIndex = button.dataset.paragraphComments;
    if (!chapter || paragraphIndex === undefined) return;
    button.disabled = true;
    button.textContent = "正在读取评论…";
    commentRequestsRef.current++;
    try {
      const result = await fetchOneParagraphComments(active.sourceBookId, chapter, paragraphIndex);
      const comments = result.comments;
      panel.replaceChildren();
      if (comments.length) {
        comments.forEach((comment) => {
          const article = document.createElement("article");
          const author = document.createElement("b");
          const content = document.createElement("p");
          author.textContent = comment.author;
          content.textContent = comment.content;
          article.append(author);
          if (comment.content) article.append(content);
          comment.images?.forEach((url) => {
            const picture = document.createElement("img");
            picture.src = proxiedCommentImage(url);
            picture.alt = "评论图片";
            picture.loading = "lazy";
            picture.referrerPolicy = "no-referrer";
            picture.addEventListener("error", () => {
              if (retryOriginalCommentImage(picture)) return;
              const fallback = document.createElement("span");
              fallback.className = "comment-image-error";
              fallback.textContent = "评论图片链接已失效，文字内容仍可正常阅读";
              picture.replaceWith(fallback);
            }, { once: true });
            article.append(picture);
          });
          if (comment.likes) {
            const likes = document.createElement("small");
            likes.textContent = `赞 ${comment.likes}`;
            article.append(likes);
          }
          panel.append(article);
        });
      } else {
        const empty = document.createElement("p");
        empty.className = "comment-empty";
        empty.textContent = "番茄返回了评论数量，但本次未返回可展示的评论正文。";
        panel.append(empty);
      }
      panel.dataset.loaded = "true";
      try {
        await dbUpdate(active.id, active, (latest) => {
          const index = latest.chapters?.findIndex((item) => item.id === chapter.id) ?? -1;
          if (index < 0 || !latest.chapters) return latest;
          const chapters = [...latest.chapters];
          chapters[index] = { ...chapters[index], version: result.version, paragraphComments: { ...(chapters[index].paragraphComments || {}), [paragraphIndex]: comments } };
          return { ...latest, chapters };
        });
      } catch (cacheError) {
        // The online result is already visible. A quota/IndexedDB failure must not
        // turn a successfully loaded comment panel into an error state.
        console.warn("评论已显示，但本地缓存失败", cacheError);
      }
    } catch (error) {
      const failure = document.createElement("p");
      failure.className = "comment-empty";
      failure.textContent = `${error instanceof Error ? error.message : "评论读取失败"}，收起后可再次点击重试。`;
      panel.append(failure);
    } finally {
      commentRequestsRef.current--;
      button.disabled = false;
      button.textContent = "收起评论";
    }
  }

  function handleCommentImageError(event: SyntheticEvent<HTMLElement>) {
    const image = event.target as HTMLImageElement;
    if (image.tagName !== "IMG" || !image.closest(".reader-comments,.paragraph-comment-panel")) return;
    if (retryOriginalCommentImage(image)) return;
    const fallback = document.createElement("span");
    fallback.className = "comment-image-error";
    fallback.textContent = "评论图片链接已失效，文字内容仍可正常阅读";
    image.replaceWith(fallback);
  }

  const flash = (message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(""), 2400);
  };

  async function parseFile(file: File): Promise<Book> {
    const ext = file.name.split(".").pop()?.toLowerCase() || "txt";
    const base: Book = { id: `${Date.now()}-${crypto.randomUUID()}`, name: file.name.replace(/\.[^.]+$/, ""), type: ext, size: file.size, updatedAt: Date.now() };
    if (["pdf", "epub"].includes(ext)) return { ...base, buffer: await file.arrayBuffer() };
    if (ext === "docx") {
      const mammoth = await import("mammoth/mammoth.browser");
      const result = await mammoth.convertToHtml({ arrayBuffer: await file.arrayBuffer() });
      return { ...base, content: safeHtml(result.value) };
    }
    const text = await file.text();
    if (["md", "markdown"].includes(ext)) return { ...base, content: safeHtml(await marked.parse(text)) };
    if (["html", "htm"].includes(ext)) return { ...base, content: safeHtml(text) };
    if (ext === "fb2") {
      const xml = new DOMParser().parseFromString(text, "application/xml");
      const body = xml.querySelector("body");
      return { ...base, content: body ? safeHtml(body.innerHTML) : textToHtml(text) };
    }
    if (ext === "rtf") {
      const plain = text.replace(/\\par[d]?/g, "\n").replace(/\\'[0-9a-f]{2}/gi, "").replace(/\\[a-z]+-?\d* ?/gi, "").replace(/[{}]/g, "");
      return { ...base, content: textToHtml(plain) };
    }
    return { ...base, content: textToHtml(text) };
  }

  async function importFiles(files: FileList | File[]) {
    const selected = Array.from(files);
    if (!selected.length) return;
    setLoading(true);
    let imported = 0;
    for (const file of selected) {
      try {
        const book = await parseFile(file);
        await dbPut(book);
        setBooks((old) => [book, ...old]);
        setActive(book);
        imported++;
      } catch (error) {
        console.error(error);
        flash(`${file.name} 解析失败`);
      }
    }
    setLoading(false);
    if (imported) flash(`已导入 ${imported} 本书，仅保存在此设备`);
  }

  async function removeBook(book: Book) {
    await dbDelete(book.id);
    setBooks((old) => old.filter((b) => b.id !== book.id));
    if (active?.id === book.id) setActive(null);
    if (localStorage.getItem("docleaf-last-book") === book.id) localStorage.removeItem("docleaf-last-book");
    flash("已从本地书架移除");
  }

  function normalizeOnlineResults(payload: any): OnlineBook[] {
    const root = payload?.data || payload || {};
    const tabs = root.search_tabs || [];
    const target = tabs.find((tab: any) => Number(tab?.tab_type) === 3)
      || tabs.find((tab: any) => tab?.title === "书籍")
      || tabs.find((tab: any) => tab?.title === "综合");
    return (target?.data || []).flatMap((item: any) => {
      const book = item?.book_data?.[0];
      if (!book?.book_id) return [];
      return [{ id: String(book.book_id), title: book.book_name || "未命名作品", author: book.author || "未知作者", description: book.abstract || "" }];
    });
  }

  async function openSource() {
    setSourceOpen(true);
    setSourceState("正在连接本地书源…");
    try {
      const response = await fetch(`${SOURCE_API}/health`);
      if (!response.ok) throw new Error();
      setSourceState("本地书源已连接，输入书名或作品 ID");
    } catch {
      setSourceState("书源服务未启动，请使用 npm run dev:full 启动");
    }
  }

  async function searchSource() {
    const query = sourceInputRef.current?.value.trim() || "";
    if (!query || sourceBusy) return;
    setSourceBusy(true);
    setSourceResults([]);
    setSourceState("正在搜索…");
    try {
      if (/^\d{15,20}$/.test(query)) {
        const response = await fetch(`${SOURCE_API}/api/detail?source=${encodeURIComponent("番茄")}&book_id=${query}&tab=${encodeURIComponent("小说")}`);
        const payload = await response.json();
        if (!response.ok || (payload.code && payload.code !== 200)) throw new Error(payload.message || "查询失败");
        const data = payload.data || {};
        setSourceResults([{ id: query, title: data.book_name || `作品 ${query}`, author: data.author || "未知作者", description: data.abstract || "" }]);
        setSourceState("");
      } else {
        const response = await fetch(`${SOURCE_API}/api/search?source=${encodeURIComponent("番茄")}&query=${encodeURIComponent(query)}&page=1&tab=${encodeURIComponent("小说")}`);
        const payload = await response.json();
        if (!response.ok || (payload.code && payload.code !== 200)) throw new Error(payload.message || "搜索失败");
        const results = normalizeOnlineResults(payload);
        setSourceResults(results);
        setSourceState(results.length ? `找到 ${results.length} 本作品` : "没有找到相关作品");
      }
    } catch (error) {
      setSourceState(error instanceof Error ? error.message : "无法连接本地书源");
    } finally {
      setSourceBusy(false);
    }
  }

  async function fetchChapterComments(bookId: string, chapterId: string) {
    try {
      const first = await fetch(`${SOURCE_API}/api/v1/chapters/${chapterId}/reviews?book_id=${bookId}`);
      const firstPayload = await first.json();
      let comments = normalizeComments(firstPayload);
      const paragraphData = collectParagraphCommentRefs(firstPayload);
      const paragraphComments = { ...paragraphData.direct };
      const ids = collectCommentIds(firstPayload);
      if (ids.length) {
        const second = await fetch(`${SOURCE_API}/api/v1/books/${bookId}/reviews?book_id=${bookId}&group_id=${chapterId}&insert_comment_ids=${ids.join(",")}`);
        if (second.ok) {
          comments = normalizeComments(await second.json()).filter((comment) => ids.includes(comment.id));
          const byId = new Map(comments.map((comment) => [comment.id, comment]));
          Object.entries(paragraphData.refs).forEach(([index, commentIds]) => {
            const matched = commentIds.map((id) => byId.get(id)).filter(Boolean) as ReaderComment[];
            if (matched.length) paragraphComments[index] = matched;
          });
        }
      }
      return { comments, paragraphComments, paragraphCommentCounts: paragraphData.counts };
    } catch {
      return { comments: [] as ReaderComment[], paragraphComments: {} as Record<string, ReaderComment[]>, paragraphCommentCounts: {} as Record<string, number> };
    }
  }

  async function fetchOneParagraphComments(bookId: string, chapter: RemoteChapter, paragraphIndex: string) {
    async function refreshVersion() {
      const directoryResponse = await fetch(`${SOURCE_API}/api/v1/books/${bookId}/directory`);
      const directoryPayload = await directoryResponse.json();
      const fresh = (directoryPayload?.data?.item_data_list || [])
        .find((item: any) => String(item.item_id || item.itemId || "") === chapter.id);
      return String(fresh?.version || "");
    }
    const currentVersion = chapter.version?.trim() || "";
    const freshVersion = await refreshVersion().catch(() => "");
    const versions = [...new Set([freshVersion, currentVersion].filter(Boolean))];
    if (!versions.length) throw new Error("章节版本暂时无法获取");
    let lastMessage = "番茄暂未返回该段评论";
    for (const version of versions) {
      for (const channel of ["38", "39"]) {
        const params = new URLSearchParams({
          book_id: bookId,
          group_id: chapter.id,
          group_type: "15",
          comment_source: "2",
          comment_type: "1",
          server_channel: channel,
          para_index: paragraphIndex,
          item_version: version,
          count: "20",
        });
        try {
          const response = await fetch(`${SOURCE_API}/api/v1/books/${bookId}/reviews?${params}`, { signal: AbortSignal.timeout(20000) });
          const payload = await response.json();
          if (!response.ok || (payload.code && payload.code !== 200)) {
            lastMessage = payload.message || `段评接口错误 ${payload.code || response.status}`;
            continue;
          }
          const comments = normalizeParagraphCommentPage(payload);
          if (comments.length) return { comments, version };
          lastMessage = "番茄返回了评论数量，但评论正文暂时为空";
        } catch (error) {
          lastMessage = error instanceof Error && error.name === "TimeoutError" ? "段评请求超时" : (error instanceof Error ? error.message : "段评读取失败");
        }
      }
    }
    throw new Error(lastMessage);
  }

  async function fetchAndStoreChapter(book: Book, index: number, refreshShelf = true) {
    const latest = await dbGet(book.id) || book;
    const chapter = latest.chapters?.[index];
    if (!chapter) throw new Error("章节不存在");
    if (chapter.content && (chapter.commentsVersion === 2 || !refreshShelf)) return { book: latest, chapter };
    let raw = chapter.content || "";
    if (!raw) {
      const response = await fetch(`${SOURCE_API}/api/content?source=${encodeURIComponent("番茄")}&book_id=${latest.sourceBookId}&item_id=${chapter.id}&tab=${encodeURIComponent("小说")}`);
      const payload = await response.json();
      if (!response.ok || (payload.code && payload.code !== 200)) throw new Error(`${chapter.title} 获取失败`);
      raw = Array.isArray(payload?.data?.content) ? payload.data.content.join("\n") : String(payload?.data?.content || "");
      if (!raw.trim()) throw new Error(`${chapter.title} 内容为空`);
    }
    const commentData = refreshShelf ? await fetchChapterComments(latest.sourceBookId || "", chapter.id) : null;
    const updated = await dbUpdate(book.id, latest, (current) => {
    const existing = current.chapters?.[index] || chapter;
    const storedChapter = { ...existing, content: normalizeRemoteContent(chapter.title, raw), ...(commentData ? { comments: commentData.comments, paragraphComments: { ...existing.paragraphComments, ...commentData.paragraphComments }, paragraphCommentCounts: commentData.paragraphCommentCounts, commentsVersion: 2 } : {}), cachedAt: Date.now() };
    const chapters = [...(current.chapters || [])];
    chapters[index] = storedChapter;
    return {
      ...current,
      chapters,
      size: chapters.reduce((sum, item) => sum + (item.content ? new Blob([item.content]).size : 0), 0),
      updatedAt: Date.now(),
    };
    });
    if (refreshShelf) setBooks((old) => old.map((item) => item.id === updated.id ? updated : item));
    return { book: updated, chapter: updated.chapters![index] };
  }

  async function loadRemoteChapter(book: Book, index: number) {
    if (!book.chapters?.length) return;
    const safeIndex = Math.max(0, Math.min(book.chapters.length - 1, index));
    const request = ++remoteLoadRef.current;
    prefetchRef.current = null;
    restoringRef.current = true;
    setRemoteLoading(true);
    setAppendError("");
    setRemoteChapterIndex(safeIndex);
    try {
      const result = await fetchAndStoreChapter(book, safeIndex);
      if (request !== remoteLoadRef.current) return;
      setRemoteContent(decorateRemoteContent(result.chapter.title, result.chapter.content || "", result.chapter.paragraphComments, result.chapter.paragraphCommentCounts));
      setReadingChapters([{ index: safeIndex, html: decorateRemoteContent(result.chapter.title, result.chapter.content || "", result.chapter.paragraphComments, result.chapter.paragraphCommentCounts, result.chapter.comments) }]);
      setRemoteComments(result.chapter.comments?.length ? result.chapter.comments : (result.book.comments || []));
      setCurrentChapter(result.chapter.title);
      const pct = Math.round(((safeIndex + 1) / (result.book.chapters?.length || 1)) * 100);
      setProgress(pct);
      localStorage.setItem(`docleaf-chapter:${book.id}`, String(safeIndex));
      localStorage.setItem(`docleaf-progress:${book.id}`, String(pct));
      pendingRestoreRef.current = { id: `${book.id}:${safeIndex}`, progress: 0 };
    } catch (error) {
      if (request === remoteLoadRef.current) {
        restoringRef.current = false;
        setRemoteContent(`<p class="reader-error">${error instanceof Error ? error.message : "章节加载失败"}，请确认书源服务已启动。</p>`);
        setRemoteComments([]);
      }
    } finally {
      if (request === remoteLoadRef.current) setRemoteLoading(false);
    }
  }

  function prefetchNextChapter() {
    if (!active || remoteLoading || appendingRef.current || commentRequestsRef.current > 0 || cacheRunRef.current) return;
    const index = (readingChapters.at(-1)?.index ?? -1) + 1;
    if (index <= 0 || index >= (active.chapters?.length || 0)) return;
    const key = `${active.id}:${index}`;
    if (prefetchRef.current?.key === key) return;
    prefetchRef.current = { key, promise: fetchAndStoreChapter(active,index,false).catch(() => undefined) };
  }

  async function appendNextChapter() {
    if (!continuous || !active?.chapters || remoteLoading || restoringRef.current || appendingRef.current || commentRequestsRef.current > 0) return;
    const last = readingChapters.at(-1);
    if (!last || last.index >= active.chapters.length - 1) return;
    const generation = remoteLoadRef.current;
    appendingRef.current = true;
    setAppendLoading(true);
    setAppendError("");
    try {
      if (prefetchRef.current?.key === `${active.id}:${last.index + 1}`) await prefetchRef.current.promise;
      const result = await fetchAndStoreChapter(active, last.index + 1);
      if (generation !== remoteLoadRef.current) return;
      const html = decorateRemoteContent(result.chapter.title, result.chapter.content || "", result.chapter.paragraphComments, result.chapter.paragraphCommentCounts, result.chapter.comments);
      setReadingChapters(old => old.some(item => item.index === last.index + 1) ? old : [...old, {index:last.index + 1, html}]);
    } catch {
      if (generation === remoteLoadRef.current) setAppendError("下一章加载失败，点击重试");
    } finally {
      appendingRef.current = false;
      setAppendLoading(false);
    }
  }

  async function cacheOnlineBook(book: Book) {
    if (cacheRunRef.current) return;
    cacheRunRef.current = book.id;
    setCacheRunning(true);
    try {
      let latest = await dbGet(book.id) || book;
      const total = latest.chapters?.length || 0;
      for (let index = 0; index < total; index++) {
        while (commentRequestsRef.current > 0) {
          await new Promise((resolve) => window.setTimeout(resolve, 250));
        }
        if (cacheRunRef.current !== book.id) break;
        if (latest.chapters?.[index]?.content) continue;
        setCacheState(`正在缓存 ${index + 1}/${total} 章`);
        const result = await fetchAndStoreChapter(latest, index, false);
        latest = result.book;
        if ((index + 1) % 10 === 0) setBooks((old) => old.map((item) => item.id === latest.id ? latest : item));
        setSourceProgress(Math.round(((index + 1) / total) * 100));
        await new Promise((resolve) => window.setTimeout(resolve, 800));
      }
      const cached = latest.chapters?.filter((chapter) => chapter.content).length || 0;
      setBooks((old) => old.map((item) => item.id === latest.id ? latest : item));
      setCacheState(cached === total ? `已离线缓存全部 ${total} 章` : `已缓存 ${cached}/${total} 章`);
    } catch (error) {
      const latest = await dbGet(book.id) || book;
      const cached = latest.chapters?.filter((chapter) => chapter.content).length || 0;
      setBooks((old) => old.map((item) => item.id === latest.id ? latest : item));
      setCacheState(`缓存暂停在 ${cached}/${latest.chapters?.length || 0} 章，点击可继续`);
    } finally {
      cacheRunRef.current = null;
      setCacheRunning(false);
    }
  }

  async function importOnlineBook(online: OnlineBook) {
    if (sourceBusy) return;
    setSourceBusy(true);
    setSourceProgress(0);
    setSourceState("正在读取目录…");
    try {
      const directoryResponse = await fetch(`${SOURCE_API}/api/v1/books/${online.id}/directory`);
      const directoryPayload = await directoryResponse.json();
      if (!directoryResponse.ok || (directoryPayload.code && directoryPayload.code !== 200)) throw new Error(directoryPayload.message || "目录获取失败");
      const chapters = (directoryPayload?.data?.item_data_list || [])
        .map((item: any) => ({ id: String(item.item_id || item.itemId || ""), title: item.title || "未命名章节", version: String(item.version || "") }))
        .filter((item: any) => item.id);
      if (!chapters.length) throw new Error("没有获取到章节目录");
      let comments: ReaderComment[] = [];
      try {
        const commentsResponse = await fetch(`${SOURCE_API}/api/v1/books/${online.id}/comments?count=20&offset=0`);
        if (commentsResponse.ok) comments = normalizeComments(await commentsResponse.json());
      } catch {}
      const book: Book = { id: `fanqie-${online.id}`, name: online.title, author: online.author, type: "fanqie", size: 0, updatedAt: Date.now(), sourceBookId: online.id, chapters, comments };
      await dbPut(book);
      setBooks((old) => [book, ...old.filter((item) => item.id !== book.id)]);
      setActive(book);
      setSearch("");
      setSideTab("library");
      setSideOpen(true);
      setSourceOpen(false);
      setRecommendOpen(false);
      setSourceState("输入书名或作品 ID");
      flash(`已加入书架，共 ${chapters.length} 章，正在打开首章`);
      void cacheOnlineBook(book);
    } catch (error) {
      setSourceState(error instanceof Error ? error.message : "导入失败");
    } finally {
      setSourceBusy(false);
    }
  }

  async function loadRankBoard(nextRankId: string, algo: number) {
    setRecommendBusy(true);
    setRecommendError("");
    try {
      const response = await fetch(`${SOURCE_API}/api/v1/rank/${nextRankId}?algo_type=${algo}&rank_sub_info_id=0`);
      const payload = await response.json();
      if (!response.ok || (payload.code && payload.code !== 200)) throw new Error(payload.message || "排行榜读取失败");
      const list = parseRankBooks(payload);
      if (!list.length) throw new Error("该榜单暂时没有可展示的书籍");
      setRecommendations(list);
      setSelectedRecommendation(list[0]);
      setRankAlgo(algo);
    } catch (error) {
      setRecommendations([]);
      setSelectedRecommendation(null);
      setRecommendError(error instanceof Error ? error.message : "排行榜读取失败");
    } finally {
      setRecommendBusy(false);
    }
  }

  async function openRecommendations() {
    setRecommendOpen(true);
    if (rankId && recommendations.length) return;
    setRecommendBusy(true);
    setRecommendError("");
    try {
      const response = await fetch(`${SOURCE_API}/api/v1/recommend/homepage?tab_type=2&offset=0`);
      const payload = await response.json();
      if (!response.ok || (payload.code && payload.code !== 200)) throw new Error(payload.message || "番茄首页读取失败");
      const card = findRankCard(payload);
      const id = String(card?.cell_id_str || card?.cell_id || "");
      const tabs = (card?.rank_with_category_data?.rank_algo_list || [])
        .map((item: any) => ({ name: String(item.rank_name || ""), algo: Number(item.rank_algo) }))
        .filter((item: RankTab) => item.name && Number.isFinite(item.algo) && !item.name.includes("剧"));
      if (!id || !tabs.length) throw new Error("没有找到番茄小说榜单");
      setRankId(id);
      setRankTabs(tabs);
      await loadRankBoard(id, tabs[0].algo);
    } catch (error) {
      setRecommendError(error instanceof Error ? error.message : "书籍推荐读取失败");
      setRecommendBusy(false);
    }
  }

  function previousChapter() {
    if (active?.type === "fanqie") void loadRemoteChapter(active, remoteChapterIndex - 1);
    else if (active?.type === "epub") renditionRef.current?.prev();
  }

  function nextChapter() {
    if (active?.type === "fanqie") void loadRemoteChapter(active, remoteChapterIndex + 1);
    else if (active?.type === "epub") renditionRef.current?.next();
  }

  const shownBooks = books.filter((book) => book.name.toLowerCase().includes(search.toLowerCase()));
  const resumeCloud = readingSync.rows.find(row=>row.book_id===active?.sourceBookId&&row.cursor&&row.revision>(readingSync.bases[row.book_id]||0)&&dismissedCloudRevision!==row.book_id+":"+row.revision);

  return (
    <main className={`app ${zen ? "zen" : ""} ${darkMode ? "dark-mode" : ""}`} onDragOver={(e) => { e.preventDefault(); setDragging(true); }} onDragLeave={() => setDragging(false)} onDrop={(e) => { e.preventDefault(); setDragging(false); importFiles(e.dataTransfer.files); }}>
      <input ref={fileRef} className="sr-only" type="file" accept={ACCEPT} multiple onChange={(e) => e.target.files && importFiles(e.target.files)} />
      <header className="titlebar">
        <div className="brand"><span className="brand-mark">D</span><strong>DocLeaf</strong><span className="saved">本地模式 · 已自动保存</span></div>
        <div className="document-title">文档</div>
        <div className="window-actions"><button aria-label="专注模式" onClick={() => setZen(!zen)}>▣</button><span>—</span><span>□</span><span>×</span></div>
      </header>

      <nav className="tabs" aria-label="功能区选项卡">
        <button onClick={()=>setSyncOpen(true)}>账号同步</button>
        <button className="file-tab" onClick={() => fileRef.current?.click()}>文件</button>
        <button className="active">开始</button><button>插入</button><button>布局</button><button>视图</button><button className="recommend-tab" onClick={openRecommendations}>书籍推荐</button>
        <button className="theme-toggle" aria-label={darkMode ? "切换浅色模式" : "切换深色模式"} aria-pressed={darkMode} onClick={() => setDarkMode(!darkMode)}>{darkMode ? "☀ 浅色" : "☾ 深色"}</button>
      </nav>

      <section className="ribbon compact-ribbon" aria-label="阅读工具栏">
        <div className="tool-group import-group">
          <button className="big-tool" onClick={() => fileRef.current?.click()}><span className="tool-icon">＋</span><b>打开书籍</b></button>
          <div className="mini-stack"><button onClick={() => { setSideOpen(!sideOpen); setSideTab("library"); }}>☰ 书架</button><button onClick={openSource}>⌕ 番茄</button></div>
          <label>书籍</label>
        </div>
        <div className="tool-group font-tools">
          <div className="control-row">
            <select aria-label="字体" value={font} onChange={(e) => setFont(e.target.value)}><option value="serif">宋体</option><option value="sans-serif">黑体</option><option value="system-ui">系统字体</option></select>
            <select aria-label="字号" value={fontSize} onChange={(e) => setFontSize(Number(e.target.value))}>{Array.from({ length: 21 }, (_, index) => index + 12).map((n) => <option key={n}>{n}</option>)}</select>
          </div>
          <div className="format-buttons"><button aria-label="增大字号" onClick={() => setFontSize(Math.min(32, fontSize + 1))}>A＋</button><button aria-label="减小字号" onClick={() => setFontSize(Math.max(12, fontSize - 1))}>A－</button><span className="font-preview">字号 {fontSize}</span></div>
          <label>字体</label>
        </div>
        <div className="tool-group">
          <div className="control-row"><span>行距</span><select aria-label="行距" value={lineHeight} onChange={(e) => setLineHeight(Number(e.target.value))}>{[...new Set([1.3,1.5,1.65,1.75,1.85,2,2.25,2.5,lineHeight])].sort((a,b) => a-b).map(value => <option key={value} value={value}>{value} 倍</option>)}</select></div>
          <label>段落</label>
          <button className="indent-toggle" aria-pressed={firstIndent} onClick={() => setFirstIndent(!firstIndent)}>首行缩进 2 字 {firstIndent ? "✓" : ""}</button>
        </div>
        <div className="tool-group paper-tools">
          <div className="paper-width-value"><b>{fitWidth ? "适应窗口" : `${Math.min(paperWidth, availablePaperWidth)}px`}</b><button aria-pressed={fitWidth} onClick={() => setFitWidth(!fitWidth)}>适应窗口</button></div>
          <div className="control-row"><span>窄</span><input aria-label="纸张宽度" type="range" min={Math.min(360, availablePaperWidth)} max={availablePaperWidth} step="1" value={fitWidth ? availablePaperWidth : Math.min(paperWidth, availablePaperWidth)} onChange={(e) => { setFitWidth(false); setPaperWidth(Number(e.target.value)); }}/><span>宽</span></div>
          <label>纸张宽度</label>
        </div>
        <div className="tool-group view-tools">
          <button aria-pressed={continuous} title="章末继续下滑，自动接上下一章" onClick={() => { setContinuous(!continuous); if (active?.type === "fanqie") void loadRemoteChapter(active, remoteChapterIndex); }}><span>⇣</span>{continuous ? "连续阅读 ✓" : "连续阅读"}</button>
          <button onClick={() => { setSideOpen(true); setSideTab("toc"); }}><span>▤</span>目录</button>
          <button onClick={() => setZen(!zen)}><span>◱</span>专注阅读</button>
          <label>视图</label>
        </div>
        <div className="tool-group chapter-tools">
          <button disabled={!active || !["fanqie", "epub"].includes(active.type) || (active.type === "fanqie" && (remoteChapterIndex <= 0 || remoteLoading))} onClick={previousChapter}><span>←</span>上一章</button>
          <button disabled={!active || !["fanqie", "epub"].includes(active.type) || (active.type === "fanqie" && (remoteChapterIndex >= (active.chapters?.length || 1) - 1 || remoteLoading))} onClick={nextChapter}><span>→</span>下一章</button>
          <label>章节</label>
        </div>
      </section>

      <div className="workspace">
        {resumeCloud&&<aside className="sync-resume"><span>云端已读到 {resumeCloud.cursor?.chapter_title}</span><button onClick={()=>void openCloudBook(resumeCloud).catch(error=>flash(error.message))}>接着读</button><button onClick={()=>setDismissedCloudRevision(resumeCloud.book_id+":"+resumeCloud.revision)}>暂不跳转</button></aside>}
        {sideOpen && <aside className="sidebar">
          <div className="side-heading"><strong>导航</strong><button aria-label="关闭书架" onClick={() => setSideOpen(false)}>×</button></div>
          <div className="side-tabs"><button className={sideTab === "library" ? "active" : ""} onClick={() => setSideTab("library")}>书架</button><button className={sideTab === "toc" ? "active" : ""} onClick={() => setSideTab("toc")} disabled={!active}>目录 {toc.length ? `(${toc.length})` : ""}</button></div>
          {sideTab === "library" ? <><div className="search"><span>⌕</span><input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索本地书籍" /></div>
          <button className="import-card" onClick={() => fileRef.current?.click()}><span>＋</span><div><b>导入书籍</b><small>EPUB、PDF、TXT、DOCX…</small></div></button>
          <div className="book-list">
            {shownBooks.map((book) => <button key={book.id} className={`book-item ${active?.id === book.id ? "selected" : ""}`} onClick={() => setActive(book)}>
              <span className={`book-cover c-${book.name.charCodeAt(0) % 5}`}>{book.name.slice(0, 1)}</span>
              <span className="book-meta"><b>{book.name}</b><small>{book.type === "fanqie" ? `番茄 · 已缓存 ${book.chapters?.filter((chapter) => chapter.content).length || 0}/${book.chapters?.length || 0} 章` : `${book.type.toUpperCase()} · ${formatSize(book.size)}`}</small></span>
              <span className="delete" role="button" aria-label={`删除 ${book.name}`} onClick={(e) => { e.stopPropagation(); removeBook(book); }}>×</span>
            </button>)}
            {!shownBooks.length && books.length > 0 && <p className="empty-hint">没有匹配的书籍</p>}
          </div></> : <div className="toc-list">{toc.length ? toc.map((item, index) => <button ref={currentChapter === item.label ? currentTocRef : undefined} key={`${item.target}-${index}`} className={currentChapter === item.label ? "current" : ""} style={{ paddingLeft: `${10 + (item.level - 1) * 12}px` }} onClick={() => jumpToc(item)}><span>{item.label}</span></button>) : <div className="toc-empty"><span>☷</span><b>未识别到目录</b><small>{active?.type === "pdf" ? "PDF 请使用阅读器自带的目录" : "带有章节标题的文件会自动生成目录"}</small></div>}</div>}
          <div className="local-note"><span>⌾</span><p><b>本地优先</b><br/>登录后可同步番茄书架与进度</p></div>
        </aside>}

        <section className={`canvas ${firstIndent ? "first-indent" : ""}`} ref={canvasRef} onScroll={trackScroll} style={{ "--paper-width": fitWidth ? "100%" : `${Math.min(paperWidth, availablePaperWidth)}px` } as CSSProperties}>
          {!active ? <div className="welcome-page">
            <div className="welcome-symbol">D</div>
            <p className="eyebrow">你的私人阅读空间</p>
            <h1>像打开文档一样，<br/>安静地读一本书。</h1>
            <p className="intro">本地书籍无需登录。需要跨端续读时，可登录同步番茄书架与进度。</p>
            <button className="primary" onClick={() => fileRef.current?.click()}>＋&nbsp; 选择本地书籍</button>
            <div className="drop-tip"><span>⇩</span>也可以直接拖入文件</div>
            <div className="formats"><span>EPUB</span><span>PDF</span><span>TXT</span><span>DOCX</span><span>MD</span><span>HTML</span><span>FB2</span><span>RTF</span></div>
            <div className="feature-row"><div><b>私密</b><small>不上传完整正文</small></div><div><b>离线</b><small>缓存后断网阅读</small></div><div><b>专注</b><small>熟悉的文档外观</small></div></div>
          </div> : active.type === "pdf" && pdfUrl ? <div className="special-reader" style={{ width: fitWidth ? "100%" : Math.min(paperWidth, availablePaperWidth), maxWidth: "100%" }}><iframe title={active.name} src={pdfUrl} /></div> : active.type === "epub" ? <div className="special-reader epub-shell" style={{ width: fitWidth ? "100%" : Math.min(paperWidth, availablePaperWidth), maxWidth: "100%" }}><div className="epub-view" ref={epubRef}/><div className="epub-controls"><button onClick={() => renditionRef.current?.prev()}>← 上一页</button><span>{progress}%</span><button onClick={() => renditionRef.current?.next()}>下一页 →</button></div></div> : active.type === "fanqie" && active.chapters?.length ? <article className={`paper remote-paper ${continuous ? "continuous-reading" : ""}`} onClick={toggleParagraphComments} onError={handleCommentImageError} style={{ fontFamily: font, fontSize, lineHeight, width: fitWidth ? "100%" : Math.min(paperWidth, availablePaperWidth), maxWidth: "100%" }}>
            <div className="remote-toolbar"><span>{active.author || "未知作者"} · {remoteChapterIndex + 1}/{active.chapters?.length || 0}</span><button disabled={cacheRunning} onClick={() => cacheOnlineBook(active)}>{cacheRunning ? cacheState || "正在缓存…" : (cacheState.includes("全部") ? cacheState : "缓存全书 / 继续缓存")}</button></div>
            <div className="rule"/>
            {remoteLoading ? <div className="chapter-loading">正在在线读取本章…</div> : readingChapters.length ? readingChapters.map(item => <section className="reading-chapter" data-reading-chapter={item.index} key={`${active.id}:${item.index}`}><ChapterBody html={item.html} /></section>) : <ChapterBody html={remoteContent} />}
            {continuous && !remoteLoading && <div className="continuous-tail">
              {appendLoading ? <span role="status">正在加载下一章…</span> : appendError ? <button onClick={() => void appendNextChapter()}>{appendError}</button> : (readingChapters.at(-1)?.index ?? 0) >= active.chapters.length - 1 ? <span>已读至本书最后一章</span> : <button onClick={() => void appendNextChapter()}>继续下滑，阅读下一章 ↓</button>}
            </div>}
            <nav className="chapter-nav"><button disabled={remoteChapterIndex <= 0 || remoteLoading} onClick={() => loadRemoteChapter(active, remoteChapterIndex - 1)}>← 上一章</button><button onClick={() => { setSideOpen(true); setSideTab("toc"); }}>目录</button><button disabled={remoteChapterIndex >= (active.chapters?.length || 1) - 1 || remoteLoading} onClick={() => loadRemoteChapter(active, remoteChapterIndex + 1)}>下一章 →</button></nav>
          </article> : <article className="paper" style={{ fontFamily: font, fontSize, lineHeight, width: fitWidth ? "100%" : Math.min(paperWidth, availablePaperWidth), maxWidth: "100%" }}><h1>{active.name}</h1><div className="rule"/><div dangerouslySetInnerHTML={{ __html: prepared.html }} /></article>}
        </section>
      </div>

      <footer className="statusbar"><span>{active ? `阅读进度 ${progress}%` : `${books.length} 本书`}</span><span className="book-status" title={active?.name}>{active?.name || ""}</span><span className="chapter-status">{currentChapter || (active ? `${active.type.toUpperCase()} · ${formatSize(active.size)}` : "")}</span><span className="status-spacer"/><span>{active?.type === "pdf" ? "使用 PDF 工具栏跳页" : "0%"}</span><input aria-label="阅读进度" className="progress-slider" type="range" min="0" max="100" value={progress} disabled={!active || active.type === "pdf"} onChange={(e) => jumpProgress(Number(e.target.value))}/>{active?.type !== "pdf" && <label className="progress-entry"><input aria-label="输入阅读进度百分比" type="number" min="0" max="100" value={progress} disabled={!active} onChange={(e) => jumpProgress(Math.max(0, Math.min(100, Number(e.target.value))))}/><span>%</span></label>}</footer>
      {dragging && <div className="drop-overlay"><div><span>⇩</span><b>松开即可加入书架</b><small>文件只会保存在本机浏览器</small></div></div>}
      {loading && <div className="loading">正在整理书籍…</div>}
      {toast && <div className="toast">✓ {toast}</div>}
      {syncOpen&&<AccountPanel onClose={()=>setSyncOpen(false)} onOpen={openCloudBook} onUpload={uploadShelf}/>}
      {sourceOpen && <div className="source-overlay" role="dialog" aria-modal="true" aria-label="番茄书源">
        <section className="source-dialog">
          <header><div><span className="source-mark">F</span><div><b>番茄书源</b><small>先加入书架 · 章节按需读取 · 支持断点缓存</small></div></div><button aria-label="关闭" onClick={() => !sourceBusy && setSourceOpen(false)}>×</button></header>
          <div className="source-search"><input ref={sourceInputRef} autoFocus onKeyDown={(e) => e.key === "Enter" && searchSource()} placeholder="输入书名或 15–20 位作品 ID"/><button disabled={sourceBusy} onClick={searchSource}>{sourceBusy && !sourceProgress ? "搜索中…" : "搜索"}</button></div>
          <div className="source-status"><span className={sourceState.includes("未启动") || sourceState.includes("失败") || sourceState.includes("无法") ? "error" : ""}>{sourceState}</span>{sourceBusy && sourceProgress > 0 && <div className="source-progress"><i style={{ width: `${sourceProgress}%` }}/></div>}</div>
          <div className="source-results">{sourceResults.map((book) => <article key={book.id}><div className="online-cover">{book.title.slice(0, 1)}</div><div><b>{book.title}</b><small>{book.author} · ID {book.id}</small><p>{book.description || "暂无简介"}</p></div><button disabled={sourceBusy} onClick={() => importOnlineBook(book)}>{sourceBusy ? "正在读取目录" : "加入书架"}</button></article>)}</div>
          <footer>内容来自第三方上游，仅供个人本地阅读；请尊重版权与平台规则。</footer>
        </section>
      </div>}
      {recommendOpen && <div className="recommend-overlay" role="dialog" aria-modal="true" aria-label="书籍推荐">
        <section className="recommend-dialog">
          <header><div><span className="recommend-mark">榜</span><div><b>书籍推荐</b><small>来自番茄小说排行榜 · 点击书籍查看简介</small></div></div><button aria-label="关闭书籍推荐" onClick={() => setRecommendOpen(false)}>×</button></header>
          <nav className="rank-tabs">{rankTabs.map((tab) => <button key={tab.algo} className={rankAlgo === tab.algo ? "active" : ""} disabled={recommendBusy} onClick={() => loadRankBoard(rankId, tab.algo)}>{tab.name}</button>)}</nav>
          <div className="recommend-body">
            <div className="rank-list">{recommendBusy ? <p className="recommend-message">正在读取番茄排行榜…</p> : recommendError ? <p className="recommend-message error">{recommendError}</p> : recommendations.map((book) => <button key={book.id} className={selectedRecommendation?.id === book.id ? "selected" : ""} onClick={() => setSelectedRecommendation(book)}><span className={`rank-number rank-${book.rank}`}>{book.rank}</span>{book.cover ? <img src={proxiedCommentImage(book.cover)} alt=""/> : <span className="rank-cover">{book.title.slice(0, 1)}</span>}<span><b>{book.title}</b><small>{book.author}{book.category ? ` · ${book.category}` : ""}</small></span></button>)}</div>
            <article className="book-intro">{selectedRecommendation ? <><div className="intro-head">{selectedRecommendation.cover ? <img src={proxiedCommentImage(selectedRecommendation.cover)} alt={`${selectedRecommendation.title}封面`}/> : <span className="intro-cover">{selectedRecommendation.title.slice(0, 1)}</span>}<div><p className="eyebrow">番茄榜单第 {selectedRecommendation.rank} 名</p><h2>{selectedRecommendation.title}</h2><p>{selectedRecommendation.author}{selectedRecommendation.category ? ` · ${selectedRecommendation.category}` : ""}</p>{selectedRecommendation.readCount && <small>{selectedRecommendation.readCount}</small>}</div></div><h3>内容简介</h3><p className="intro-text">{selectedRecommendation.description || "暂无简介"}</p><button className="recommend-add" disabled={sourceBusy || books.some((book) => book.sourceBookId === selectedRecommendation.id)} onClick={() => importOnlineBook(selectedRecommendation)}>{books.some((book) => book.sourceBookId === selectedRecommendation.id) ? "已在书架" : "加入书架"}</button></> : <p className="recommend-message">从左侧选择一本书查看简介</p>}</article>
          </div>
        </section>
      </div>}
    </main>
  );
}
