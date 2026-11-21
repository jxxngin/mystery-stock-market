-- v6: 대기방 채팅 (v5_new_mechanics.sql 이후 적용)
--  · 대기방(lobby)에서만 보낼 수 있고, 최근 50개를 get_state로 전달
--  · 게임이 시작되면 그 방의 채팅은 삭제

create table if not exists public.chats (
  id bigserial primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  name text not null,
  msg text not null,
  created_at timestamptz not null default now()
);
create index if not exists chats_room_idx on public.chats(room_id, id);
alter table public.chats enable row level security;
revoke all on public.chats from anon, authenticated;

create or replace function public.send_chat(p_player uuid, p_secret uuid, p_msg text) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms; last_at timestamptz;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id;
  if r.status <> 'lobby' then raise exception '채팅은 대기방에서만 할 수 있어요'; end if;
  p_msg := btrim(coalesce(p_msg, ''));
  if p_msg = '' then return; end if;
  if char_length(p_msg) > 200 then raise exception '채팅은 200자까지 보낼 수 있어요'; end if;
  select max(created_at) into last_at from chats where player_id = me.id;
  if last_at is not null and last_at > now() - interval '500 milliseconds' then raise exception '조금 천천히 보내주세요'; end if;
  insert into chats(room_id, player_id, name, msg) values (r.id, me.id, me.name, p_msg);
end $$;
revoke execute on function public.send_chat(uuid, uuid, text) from public;
grant execute on function public.send_chat(uuid, uuid, text) to anon, authenticated;

do $$
declare d text; d2 text;
begin
  -- start_game: 시작할 때 대기방 채팅 삭제
  d := pg_get_functiondef('public.start_game(uuid,uuid)'::regprocedure);
  d2 := replace(d, '  update rooms set status = ''playing'', round = 1,',
                   '  delete from chats where room_id = r.id;
  update rooms set status = ''playing'', round = 1,');
  if d2 = d then raise exception 'start_game patch failed'; end if;
  execute d2;

  -- get_state: 대기방일 때 최근 채팅 50개
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$'events', ev,$x$,
    $x$'events', ev,
    'chat', case when r.status = 'lobby' then (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
        'me', c.player_id = me.id, 'msg', c.msg, 'at', floor(extract(epoch from c.created_at) * 1000)) order by c.id), '[]')
      from (select * from chats where room_id = r.id order by id desc limit 50) c) else '[]'::jsonb end,$x$);
  if d2 = d then raise exception 'get_state patch failed'; end if;
  execute d2;
end $$;
