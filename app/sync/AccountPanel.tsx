"use client";
import {useEffect,useState} from "react";
import {readingSync,type CloudBook} from "./client";
export function AccountPanel({onClose,onOpen,onUpload}:{onClose:()=>void;onOpen:(book:CloudBook)=>Promise<void>;onUpload:()=>void}){
  const [,refresh]=useState(0),[name,setName]=useState(""),[password,setPassword]=useState(""),[register,setRegister]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState("");
  useEffect(()=>readingSync.subscribe(()=>refresh(n=>n+1)),[]);
  const run=async(fn:()=>Promise<void>)=>{setBusy(true);setError("");try{await fn();}catch(e){setError(e instanceof Error?e.message:"操作失败");}finally{setBusy(false);}};
  return <div className="source-overlay" role="dialog" aria-modal="true" aria-label="账号与阅读同步"><section className="source-dialog sync-dialog">
    <header><div><b>账号与阅读同步</b></div><button aria-label="关闭同步面板" onClick={onClose}>×</button></header>
    <div className="sync-content">
      <p>网页与安卓版登录同一账号，即可同步番茄书架和阅读位置。与股票工具共用账号，阅读数据独立。</p>
      {!readingSync.session?<form onSubmit={e=>{e.preventDefault();void run(async()=>{await readingSync.login(name,password,register);setPassword("");});}}>
        <label>用户名<input required value={name} onChange={e=>setName(e.target.value)} autoComplete="username"/></label>
        <label>密码<input required type="password" minLength={6} value={password} onChange={e=>setPassword(e.target.value)} autoComplete={register?"new-password":"current-password"}/></label>
        <button disabled={busy}>{busy?"请稍候…":register?"创建账号":"登录"}</button>
        <button type="button" onClick={()=>setRegister(!register)}>{register?"已有账号，去登录":"没有账号，注册"}</button>
      </form>:<><p>当前账号：{readingSync.session.user.user_metadata?.username||"已登录"}</p>
        <div className="sync-actions"><button disabled={busy} onClick={()=>void run(()=>readingSync.sync())}>立即同步</button><button onClick={onUpload}>合并本地番茄书架</button><button disabled={busy} onClick={()=>readingSync.logout()}>退出登录</button></div>
        {Object.entries(readingSync.conflicts).map(([id,row])=><article className="sync-conflict" key={id}><b>{row.title}</b><p>另一设备：{row.cursor?.chapter_title||"尚未阅读"}。本机有未同步记录，请选择。</p><button onClick={()=>void run(()=>readingSync.resolve(id,false))}>保留云端进度</button><button onClick={()=>void run(()=>readingSync.resolve(id,true))}>使用本机进度</button></article>)}
        <h3>云端书架</h3>{readingSync.rows.map(row=><article className="sync-book" key={row.book_id}><div><b>{row.title}</b><small>{row.cursor?.chapter_title||"尚未阅读"} · {row.author}</small></div><button disabled={busy||Boolean(readingSync.conflicts[row.book_id])} onClick={()=>void run(async()=>{await onOpen(row);onClose();})}>继续阅读</button></article>)}
        {!readingSync.rows.length&&<p>还没有云端书籍，点击“合并本地番茄书架”。</p>}
      </>}
      <p role="status">{readingSync.status}</p>{error&&<p className="reader-error">{error}</p>}
      <small>断网时继续本地阅读；联网后补传。仅同步书籍信息、位置和最多 32 字符的定位片段，不上传完整正文、评论或本地文件。</small>
    </div>
  </section></div>;
}
