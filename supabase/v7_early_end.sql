-- v7: 전원 동의 시 게임 조기 종료 (v6_lobby_chat.sql 이후 적용)
--  · 게임 중 각자 '게임 끝내기'에 동의/취소할 수 있다 (라운드 종료 투표와 별개)
--  · 접속 중인 전원이 동의하면 즉시 종료: 마지막으로 정산된 라운드의 주가·자산으로 최종 순위
--  · rooms.final_round = 결과 기준 라운드 (끝까지 하면 24, 조기 종료면 그 직전 정산 라운드)

alter table public.players add column if not exists end_game_vote boolean not null default false;
alter table public.rooms add column if not exists final_round int;

create or replace function public.set_endgame_vote(p_player uuid, p_secret uuid, p_vote boolean) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id;
  if r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  update players set end_game_vote = p_vote, last_seen = now() where id = me.id;
  insert into events(room_id, round, msg) values (r.id, r.round,
    case when p_vote then '누군가 게임 조기 종료에 동의했습니다' else '누군가 게임 조기 종료 동의를 취소했습니다' end);
  perform ms_tick(me.room_id);
end $$;
revoke execute on function public.set_endgame_vote(uuid, uuid, boolean) from public;
grant execute on function public.set_endgame_vote(uuid, uuid, boolean) to anon, authenticated;

do $$
declare d text; d2 text;
begin
  -- ms_tick: 접속 중 전원이 조기 종료에 동의하면 즉시 종료
  d := pg_get_functiondef('public.ms_tick(uuid)'::regprocedure);
  d2 := replace(d, $x$  if r.status <> 'playing' then return; end if;$x$,
    $x$  if r.status <> 'playing' then return; end if;
  if exists (select 1 from players where room_id = rid and last_seen > now() - interval '15 seconds')
     and not exists (select 1 from players where room_id = rid and last_seen > now() - interval '15 seconds' and not end_game_vote) then
    update rooms set status = 'finished', final_round = greatest(r.round - 1, 0), countdown_end = null, countdown_reason = null
      where id = rid and status = 'playing';
    if found then
      insert into events(room_id, round, msg) values (rid, r.round, '전원 동의로 게임을 조기 종료했습니다');
    end if;
    return;
  end if;$x$);
  if d2 = d then raise exception 'ms_tick patch failed'; end if;
  execute d2;

  -- ms_resolve: 24라운드까지 끝나면 final_round = 24
  d := pg_get_functiondef('public.ms_resolve(uuid)'::regprocedure);
  d2 := replace(d, $x$status = case when t >= 24 then 'finished' else 'playing' end,$x$,
                   $x$status = case when t >= 24 then 'finished' else 'playing' end,
    final_round = case when t >= 24 then 24 else final_round end,$x$);
  if d2 = d then raise exception 'ms_resolve patch failed'; end if;
  execute d2;

  -- get_state: 결과 기준 라운드, 조기 종료 투표 현황
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$lr := case when r.status = 'finished' then 24 else r.round - 1 end;$x$,
                   $x$lr := case when r.status = 'finished' then coalesce(r.final_round, 24) else r.round - 1 end;$x$);
  d2 := replace(d2, $x$'is_host', r.host_id = me.id,$x$, $x$'is_host', r.host_id = me.id, 'final_round', r.final_round,$x$);
  d2 := replace(d2, $x$'blind_used', me.blind_used,$x$, $x$'blind_used', me.blind_used, 'end_game_vote', me.end_game_vote,$x$);
  d2 := replace(d2, $x$'online', pl.last_seen > now() - interval '15 seconds', 'vote', pl.end_vote)$x$,
                    $x$'online', pl.last_seen > now() - interval '15 seconds', 'vote', pl.end_vote, 'gvote', pl.end_game_vote)$x$);
  d2 := replace(d2, $x$'votes', jsonb_build_object('active', act, 'votes', vts,$x$,
                    $x$'votes', jsonb_build_object('active', act, 'votes', vts,
      'game_votes', (select count(*) from players pl where pl.room_id = r.id and pl.end_game_vote and pl.last_seen > now() - interval '15 seconds'),$x$);
  if position('coalesce(r.final_round, 24)' in d2) = 0 or position('''gvote''' in d2) = 0 or position('''game_votes''' in d2) = 0
     or position('''end_game_vote''' in d2) = 0 or position('''final_round''' in d2) = 0 then
    raise exception 'get_state patch failed';
  end if;
  execute d2;
end $$;
