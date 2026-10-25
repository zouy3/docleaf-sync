-- Run once in the existing stock project's Supabase SQL Editor.
-- Adds only docleaf data. Never modifies quiet_watchlist or auth accounts.
begin;
create table if not exists public.docleaf_books (
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id text not null check (book_id ~ '^[0-9]{1,30}$'),
  title text not null check (char_length(title) between 1 and 300),
  author text not null default '',
  cover text not null default '',
  cursor jsonb,
  revision bigint not null default 0,
  device_id text not null default '',
  updated_at timestamptz not null default now(),
  primary key (user_id, book_id),
  check (cursor is null or coalesce((
    jsonb_typeof(cursor) = 'object' and cursor->>'chapter_id' ~ '^[0-9]{1,30}$'
    and (cursor->>'ordinal')::integer >= 0
    and (cursor->>'character_offset')::integer >= 0
  ), false))
);
alter table public.docleaf_books enable row level security;
revoke all on public.docleaf_books from anon, authenticated;
grant select on public.docleaf_books to authenticated;
drop policy if exists docleaf_read_own on public.docleaf_books;
create policy docleaf_read_own on public.docleaf_books for select to authenticated
  using (user_id = (select auth.uid()));

-- All writes go through CAS: stale/offline devices cannot overwrite a newer
-- cursor. Metadata-only bookshelf additions never reset an existing cursor.
create or replace function public.docleaf_save(
  p_book_id text, p_title text, p_author text, p_cover text,
  p_cursor jsonb, p_expected_revision bigint, p_device_id text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  existing public.docleaf_books;
begin
  if uid is null then raise exception 'login required' using errcode = '42501'; end if;
  insert into public.docleaf_books(user_id, book_id, title, author, cover)
    values(uid, p_book_id, p_title, coalesce(p_author,''), coalesce(p_cover,''))
    on conflict do nothing;
  select * into existing from public.docleaf_books
    where user_id = uid and book_id = p_book_id for update;
  if p_cursor is not null and existing.revision <> p_expected_revision then
    return jsonb_build_object('status','conflict','row',to_jsonb(existing));
  end if;
  update public.docleaf_books set title = p_title,
    author = coalesce(nullif(p_author,''), existing.author), cover = coalesce(nullif(p_cover,''), existing.cover),
    cursor = coalesce(p_cursor, existing.cursor),
    revision = existing.revision + 1,
    device_id = p_device_id, updated_at = now()
    where user_id = uid and book_id = p_book_id
    returning * into existing;
  return jsonb_build_object('status','saved','row',to_jsonb(existing));
end;
$$;
revoke all on function public.docleaf_save(text,text,text,text,jsonb,bigint,text) from public, anon;
grant execute on function public.docleaf_save(text,text,text,text,jsonb,bigint,text) to authenticated;
commit;
