-- v9: 방장이 대기방에서 참가자를 내보내기 (v8_secret_history.sql 이후 적용)
--  · 대기방(lobby)에서만, 방장만, 자기 자신은 불가
--  · 내보낸 사람의 다음 요청은 "방장이 방에서 내보냈어요"로 실패 → 화면이 홈으로 돌아감
--  · 같은 이름으로 같은 방에 다시 들어오는 것은 막음

create table if not exists public.kicked (
  player_id uuid primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  at timestamptz not null default now()
);
create index if not exists kicked_room_idx on public.kicked(room_id);
alter table public.kicked enable row level security;
revoke all on public.kicked from anon, authenticated;

create or replace function public.ms_auth(p_player uuid, p_secret uuid) returns public.players language plpgsql security definer set search_path = public as $$
declare me players;
begin
  select * into me from players where id = p_player and secret = p_secret;
  if not found then
    if exists (select 1 from kicked where player_id = p_player) then
      raise exception '방장이 방에서 내보냈어요';
    end if;
    raise exception '인증 실패: 다시 입장해주세요';
  end if;
  return me;
end $$;
revoke execute on function public.ms_auth(uuid, uuid) from public, anon, authenticated;

create or replace function public.kick_player(p_player uuid, p_secret uuid, p_target uuid) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms; t players;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception '방장만 내보낼 수 있어요'; end if;
  if r.status <> 'lobby' then raise exception '게임 시작 전에만 내보낼 수 있어요'; end if;
  if p_target = me.id then raise exception '자기 자신은 내보낼 수 없어요'; end if;
  select * into t from players where id = p_target and room_id = r.id;
  if not found then raise exception '이 방에 없는 참가자예요'; end if;
  insert into kicked(player_id, room_id, name) values (t.id, r.id, t.name) on conflict (player_id) do nothing;
  delete from players where id = t.id;  -- 보유·채팅은 on delete cascade
  insert into events(room_id, round, msg) values (r.id, 0, t.name || ' 님을 방장이 내보냈습니다');
end $$;
revoke execute on function public.kick_player(uuid, uuid, uuid) from public;
grant execute on function public.kick_player(uuid, uuid, uuid) to anon, authenticated;

do $$
declare d text; d2 text;
begin
  -- join_room: 내보내진 이름은 같은 방에 다시 못 들어옴
  d := pg_get_functiondef('public.join_room(text,text)'::regprocedure);
  d2 := replace(d, $x$  if exists (select 1 from players where room_id = r.id and name = p_name) then raise exception '이미 사용 중인 이름이에요'; end if;$x$,
    $x$  if exists (select 1 from players where room_id = r.id and name = p_name) then raise exception '이미 사용 중인 이름이에요'; end if;
  if exists (select 1 from kicked where room_id = r.id and name = p_name) then raise exception '방장이 내보낸 이름이라 이 방에 다시 들어올 수 없어요'; end if;$x$);
  if d2 = d then raise exception 'join_room patch failed'; end if;
  execute d2;
end $$;
