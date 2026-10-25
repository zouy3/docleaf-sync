export type ReadingCursor = {
  version: 1; chapter_id: string; chapter_index: number; chapter_title: string;
  paragraph_id: string | null; ordinal: number; character_offset: number; quote: string;
};
export type CloudBook = {
  book_id: string; title: string; author: string; cover: string;
  cursor: ReadingCursor | null; revision: number; device_id: string; updated_at: string;
};
type Session = { access_token:string; refresh_token:string; expires_at:number; user:{id:string; user_metadata?:{username?:string}} };
type Pending = { book: Pick<CloudBook,"book_id"|"title"|"author"|"cover">; cursor:ReadingCursor|null; base:number; sequence:number };
export const SYNC_URL = "https://vfuznbboqrxmrlirdwti.supabase.co";
export const SYNC_KEY = "sb_publishable_1OFiLFqzp9c3SSb0xdfriA_TF6bBAZF";
export const canonicalText = (text:string) => text.replace(/[\s\u200b\ufeff]+/g,"");
// PostgreSQL JSON rejects lone UTF-16 surrogates; never cut an emoji in half.
export function positionQuote(text:string,offset:number){
  if(offset>0&&/[\udc00-\udfff]/.test(text[offset]||""))offset--;
  return text.slice(offset,offset+32).replace(/[\ud800-\udbff]$/,"");
}
export function accountEmail(username:string) {
  const name=username.normalize("NFKC").trim().toLowerCase();
  if (!/^[a-z0-9_-]{3,32}$/.test(name)) throw Error("用户名为 3–32 位字母、数字、下划线或短横线");
  return name+"@users.quiet-notes.invalid";
}
export class ReadingSync {
  session:Session|null=null;
  rows:CloudBook[]=[];
  pending:Record<string,Pending>={};
  conflicts:Record<string,CloudBook>={};
  bases:Record<string,number>={};
  status="未登录 · 本地阅读";
  private listeners=new Set<()=>void>();
  private timer:ReturnType<typeof setTimeout>|null=null;
  private refreshing:Promise<string>|null=null;
  private running=false;
  private generation=0;
  private sequence=0;
  private device="";
  private restored=false;
  subscribe=(callback:()=>void)=>{this.listeners.add(callback);return ()=>{this.listeners.delete(callback);};};
  private emit(){this.listeners.forEach(fn=>fn());}
  private key(){return "docleaf-sync:"+this.session!.user.id;}
  init(){
    if(this.restored)return;
    this.restored=true;
    try{this.session=JSON.parse(localStorage.getItem("docleaf-sync-session")||"null");}catch{}
    this.device=localStorage.getItem("docleaf-sync-device")||crypto.randomUUID();
    localStorage.setItem("docleaf-sync-device",this.device);
    this.restoreAccount();
  }
  private restoreAccount(){
    this.rows=[];this.pending={};this.conflicts={};this.bases={};
    if(this.session)try{const data=JSON.parse(localStorage.getItem(this.key())||"{}");this.rows=data.rows||[];this.pending=data.pending||{};this.bases=data.bases||{};}catch{}
    this.sequence=Math.max(this.sequence,...Object.values(this.pending).map(item=>item.sequence||0));
    this.status=this.session?"已登录 · 等待同步":"未登录 · 本地阅读";this.emit();
  }
  private persist(){if(this.session)localStorage.setItem(this.key(),JSON.stringify({rows:this.rows,pending:this.pending,bases:this.bases}));}
  acceptRemote(row:CloudBook){this.bases[row.book_id]=row.revision;delete this.pending[row.book_id];delete this.conflicts[row.book_id];this.persist();}
  private async request(path:string,method="GET",body?:unknown,token?:string){
    const response=await fetch(SYNC_URL+path,{method,headers:{apikey:SYNC_KEY,...(token?{Authorization:"Bearer "+token}:{}),...(body!==undefined?{"Content-Type":"application/json"}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
    const data=await response.json().catch(()=>null);
    if(!response.ok){
      const code=data?.code||data?.error_code;
      throw Error(code==="PGRST205"||code==="PGRST202"||code==="42P01"?"云端尚未初始化，请运行 sync/schema.sql":code==="invalid_credentials"?"用户名或密码错误":data?.message||data?.msg||data?.error_description||"同步请求失败");
    }
    return data;
  }
  async login(username:string,password:string,register=false){
    const generation=++this.generation;
    const email=accountEmail(username);
    const data=await this.request(register?"/auth/v1/signup":"/auth/v1/token?grant_type=password","POST",{email,password,...(register?{data:{username:username.trim().toLowerCase()}}:{})});
    if(generation!==this.generation)return;
    if(!data?.access_token)throw Error("账号需要邮箱确认，请检查现有项目的注册设置");
    this.session={...data,expires_at:data.expires_at||Date.now()/1000+data.expires_in};
    localStorage.setItem("docleaf-sync-session",JSON.stringify(this.session));this.restoreAccount();
    await this.sync();
  }
  logout(){
    this.persist();this.generation++;this.session=null;
    if(this.timer)clearTimeout(this.timer);
    localStorage.removeItem("docleaf-sync-session");this.restoreAccount();
  }
  private async token():Promise<string>{
    if(!this.session)throw Error("请先登录");
    if(this.session.expires_at>Date.now()/1000+60)return this.session.access_token;
    if(this.refreshing)return this.refreshing;
    const generation=this.generation,refresh=this.session.refresh_token;
    this.refreshing=this.request("/auth/v1/token?grant_type=refresh_token","POST",{refresh_token:refresh}).then(data=>{
      if(generation!==this.generation)throw Error("账号已切换");
      this.session={...data,expires_at:data.expires_at||Date.now()/1000+data.expires_in};
      localStorage.setItem("docleaf-sync-session",JSON.stringify(this.session));return data.access_token;
    }).finally(()=>{this.refreshing=null;});
    return this.refreshing;
  }
  queue(book:Pending["book"],cursor:ReadingCursor|null){
    if(!this.session||!/^[0-9]{1,30}$/.test(book.book_id))return;
    const previous=this.pending[book.book_id];
    this.pending[book.book_id]={book,cursor:cursor||previous?.cursor||null,base:previous?.base??this.bases[book.book_id]??0,sequence:++this.sequence};
    this.persist();this.status="进度已保存本地 · 待同步";this.emit();
    // Do not postpone forever while the user scrolls continuously.
    if(!this.timer)this.timer=setTimeout(()=>{this.timer=null;void this.sync();},5000);
  }
  async sync(){
    if(!this.session||this.running)return;
    this.running=true;const generation=this.generation;
    this.status="正在同步…";this.emit();
    try{
      const token=await this.token();
      if(generation!==this.generation)return;
      for(const [id,item] of Object.entries({...this.pending})){
        if(this.conflicts[id])continue;
        const result=await this.request("/rest/v1/rpc/docleaf_save","POST",{p_book_id:id,p_title:item.book.title,p_author:item.book.author,p_cover:item.book.cover,p_cursor:item.cursor,p_expected_revision:item.base,p_device_id:this.device},token);
        if(generation!==this.generation)return;
        const row=result.row as CloudBook;
        if(result.status==="conflict"){this.conflicts[id]=row;continue;}
        this.rows=[...this.rows.filter(x=>x.book_id!==id),row];
        this.bases[id]=row.revision;
        if(this.pending[id]?.sequence===item.sequence)delete this.pending[id];
        else if(this.pending[id])this.pending[id].base=row.revision;
        this.persist();
      }
      const rows:CloudBook[]=[];
      for(let offset=0;;offset+=500){
        const chunk=await this.request("/rest/v1/docleaf_books?select=*&order=updated_at.desc&limit=500&offset="+offset,"GET",undefined,token);
        if(generation!==this.generation)return;
        rows.push(...chunk);if(chunk.length<500)break;
      }
      this.rows=rows;this.persist();
      this.status=Object.keys(this.conflicts).length?"有进度冲突，请选择保留哪一份":Object.keys(this.pending).length?"本地仍有待同步进度":"同步完成";
    }catch(error){if(generation===this.generation)this.status=(error instanceof Error?error.message:"网络不可达")+" · 本地阅读不受影响";}
    finally{this.running=false;this.emit();}
  }
  async resolve(id:string,useLocal:boolean){
    const remote=this.conflicts[id];if(!remote)return;
    if(useLocal&&this.pending[id])this.pending[id].base=remote.revision;
    else {delete this.pending[id];this.bases[id]=remote.revision;}
    delete this.conflicts[id];this.persist();await this.sync();
  }
}
export const readingSync=new ReadingSync();
