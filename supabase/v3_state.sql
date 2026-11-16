-- v3: 라운드별 기록(보유자 수 포함) · 시크릿 남은 라운드 · 순위 변동 (v2_mechanics.sql 이후 적용)

-- 객체에서 지정한 키의 값을 null로 가린다
create or replace function public.ms_mask(o jsonb, k text[]) returns jsonb language sql immutable set search_path = public as
$$ select case when o is null then null else coalesce((select jsonb_object_agg(e.key, case when e.key = any(k) then 'null'::jsonb else e.value end) from jsonb_each(o) e), o) end $$;

-- ms_resolve: 기록에 보유자 수(holders) 추가
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.ms_resolve(uuid)'::regprocedure);
  d2 := replace(d, $x$'buy', bu, 'sell', se, 'hold', hn));$x$,
    $x$'buy', bu, 'sell', se, 'hold', hn,
      'holders', (select jsonb_object_agg(x, (select count(*) from holdings h2 where h2.room_id = rid and h2.stock = x and h2.qty > 0)) from unnest(ms_stocks()) x)));$x$);
  if d2 = d then raise exception 'ms_resolve patch failed'; end if;
  execute d2;
end $$;

create or replace function public.get_state(p_player uuid, p_secret uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me players; r rooms; stg int := 0; s text; lastrow jsonb; hidden_now text[] := '{}'; st jsonb := '[]';
  hist jsonb; rk jsonb; pls jsonb; ev jsonb; act int; vts int; fin jsonb; hold jsonb; lvl int; hid boolean; lr int; left_r int;
begin
  me := ms_auth(p_player, p_secret);
  update players set last_seen = now() where id = me.id;
  perform ms_tick(me.room_id);
  select * into me from players where id = p_player;
  select * into r from rooms where id = me.room_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.name, 'host', pl.id = r.host_id,
           'online', pl.last_seen > now() - interval '15 seconds', 'vote', pl.end_vote) order by pl.joined_at), '[]')
    into pls from players pl where pl.room_id = r.id;
  select count(*), count(*) filter (where pl.end_vote) into act, vts
    from players pl where pl.room_id = r.id and pl.last_seen > now() - interval '15 seconds';
  select coalesce(jsonb_object_agg(h.stock, h.qty), '{}') into hold from holdings h where h.player_id = me.id and h.qty > 0;
  select coalesce(jsonb_agg(jsonb_build_object('round', e.round, 'msg', e.msg) order by e.id desc), '[]')
    into ev from (select * from events where room_id = r.id order by id desc limit 12) e;

  if r.status <> 'lobby' then
    stg := case when r.status = 'finished' then 4 else ms_stage(r.round) end;
    lr := case when r.status = 'finished' then 24 else r.round - 1 end;
    if r.status = 'playing' then
      select coalesce(array_agg(distinct b.stock), '{}') into hidden_now from blinds b
        where b.room_id = r.id and r.round between b.start_round and b.end_round;
    end if;
    select h.data into lastrow from history h where h.room_id = r.id and h.round = lr;
    foreach s in array ms_stocks() loop
      hid := s = any(hidden_now);
      left_r := null;
      if hid then
        select max(b.end_round) - r.round + 1 into left_r from blinds b
          where b.room_id = r.id and b.stock = s and r.round between b.start_round and b.end_round;
      end if;
      lvl := case when r.status = 'finished' then 4 else greatest(stg, coalesce((me.peeks->>s)::int, 0)) end;
      st := st || jsonb_build_array(jsonb_build_object('name', s, 'hidden', hid, 'secret_left', left_r,
        'price',   case when hid then null else lastrow->'prices'->s end,
        'change',  case when hid then null else lastrow->'change'->s end,
        'buy',     case when hid then null else lastrow->'buy'->s end,
        'sell',    case when hid then null else lastrow->'sell'->s end,
        'hold',    case when hid then null else lastrow->'hold'->s end,
        'holders', case when hid then null else lastrow->'holders'->s end,
        'rule', ms_rule_view(s, r.params, r.masks, lvl), 'parts', ms_rule_parts(s, r.params, r.masks, lvl, stg),
        'level', lvl, 'peeked', coalesce((me.peeks->>s)::int, 0) > stg));
    end loop;

    -- 라운드별 전체 기록 (시크릿 기간 중인 칸은 가림)
    select jsonb_agg(jsonb_build_object('round', q.round,
             'prices',  ms_mask(q.data->'prices', q.hk),  'change', ms_mask(q.data->'change', q.hk),
             'buy',     ms_mask(q.data->'buy', q.hk),     'sell',   ms_mask(q.data->'sell', q.hk),
             'hold',    ms_mask(q.data->'hold', q.hk),    'holders', ms_mask(q.data->'holders', q.hk)) order by q.round)
      into hist
      from (select h.round, h.data,
              case when r.status = 'playing' then coalesce((select array_agg(b.stock) from blinds b
                where b.room_id = r.id and h.round + 1 between b.start_round and b.end_round and r.round <= b.end_round), '{}')
              else '{}'::text[] end as hk
            from history h where h.room_id = r.id) q;

    -- 순위 + 직전 라운드 대비 변동(양수 = 상승)
    with cur as (
      select a.player_id, a.asset, pl.name, row_number() over (order by a.asset desc, pl.cash desc) as rn
      from asset_history a join players pl on pl.id = a.player_id where a.room_id = r.id and a.round = lr
    ), prev as (
      select a.player_id, row_number() over (order by a.asset desc, pl.cash desc) as rn
      from asset_history a join players pl on pl.id = a.player_id where a.room_id = r.id and a.round = lr - 1
    )
    select coalesce(jsonb_agg(jsonb_build_object('name', cur.name, 'me', cur.player_id = me.id,
             'asset', case when cardinality(hidden_now) > 0 then null else cur.asset end,
             'delta', prev.rn - cur.rn) order by cur.rn), '[]')
      into rk from cur left join prev on prev.player_id = cur.player_id;

    if r.status = 'finished' then
      fin := jsonb_build_object('params', r.params,
        'assets', (select jsonb_agg(jsonb_build_object('name', pl.name,
                     'series', (select jsonb_agg(a.asset order by a.round) from asset_history a where a.player_id = pl.id)))
                   from players pl where pl.room_id = r.id));
    end if;
  end if;

  return jsonb_build_object(
    'now', floor(extract(epoch from clock_timestamp()) * 1000),
    'room', jsonb_build_object('code', r.code, 'status', r.status, 'round', r.round, 'stage', stg,
      'is_host', r.host_id = me.id, 'countdown', r.countdown_end is not null, 'countdown_reason', r.countdown_reason,
      'round_started_at', floor(extract(epoch from r.round_started_at) * 1000)),
    'me', jsonb_build_object('id', me.id, 'name', me.name, 'cash', me.cash, 'tokens', me.tokens,
      'blind_used', me.blind_used, 'vote', me.end_vote, 'holdings', hold),
    'players', pls,
    'votes', jsonb_build_object('active', act, 'votes', vts, 'need', greatest(1, ceil(act * 0.7))::int),
    'stocks', st, 'history', coalesce(hist, '[]'), 'ranking', coalesce(rk, '[]'), 'events', ev, 'final', fin);
end $$;

revoke execute on function public.ms_mask(jsonb, text[]) from public, anon, authenticated;
revoke execute on function public.get_state(uuid, uuid) from public;
grant execute on function public.get_state(uuid, uuid) to anon, authenticated;
