-- v5: 메커니즘 추가/삭제 + 모양 교체 (v4_item_counts.sql 이후 적용)
--  추가: hot(인기 과열) lonely(소외주) parity(홀짝) monopoly(독점 금지) streak(과열 붕괴) cycle(주기)
--  삭제: revert(가격 회귀)는 뽑기 후보에서 제외 (진행 중인 옛 판 호환을 위해 계산 코드는 남김)
--  모양: U자 제거, 함정 · 롤러코스터 · 심전도 추가 → W / M / 계단 / 번개 / 쌍봉 / 함정 / 롤러코스터 / 심전도

-- 방장 아이템 설정 (null = 인원별 자동)
alter table public.rooms add column if not exists cfg_tokens int;
alter table public.rooms add column if not exists cfg_secrets int;

create or replace function public.set_items(p_player uuid, p_secret uuid, p_tokens int, p_secrets int) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception '방장만 아이템 개수를 바꿀 수 있어요'; end if;
  if r.status <> 'lobby' then raise exception '게임 시작 전에만 바꿀 수 있어요'; end if;
  if p_tokens is not null and (p_tokens < 0 or p_tokens > 5) then raise exception '정보 토큰은 0~5개로 정해주세요'; end if;
  if p_secrets is not null and (p_secrets < 0 or p_secrets > 5) then raise exception '시크릿은 0~5개로 정해주세요'; end if;
  update rooms set cfg_tokens = p_tokens, cfg_secrets = p_secrets where id = r.id;
end $$;
revoke execute on function public.set_items(uuid, uuid, int, int) from public;
grant execute on function public.set_items(uuid, uuid, int, int) to anon, authenticated;

do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$'is_host', r.host_id = me.id,$x$, $x$'is_host', r.host_id = me.id, 'cfg_tokens', r.cfg_tokens, 'cfg_secrets', r.cfg_secrets,$x$);
  if d2 = d then raise exception 'get_state patch failed'; end if;
  execute d2;
end $$;

create or replace function public.ms_shape(idx int) returns numeric[] language sql immutable set search_path = public as $$
select case idx
  when 1 then array[10,9,8,7,6,5,6.5,8,9.5,11,12,11,10,9,8,7,8,9.5,11,12.5,14,15,16,17,18]::numeric[]                 -- W
  when 2 then array[10,11.5,13,14.5,16,17.5,16,14.5,13,11.5,10,11.5,13,14.5,16,17.5,16,14,12,10,8,6.5,5,4,3]::numeric[] -- M
  when 3 then array[10,10,12,12,12,14,14,14,16,16,16,18,18,18,16,16,18,20,20,20,22,22,22,24,24]::numeric[]            -- 계단
  when 4 then array[10,13,8,11,6,9,4,7,3,6,2,5,8,4,7,10,6,9,12,8,11,14,10,13,16]::numeric[]                          -- 번개
  when 5 then array[10,12,14,16,18,20,18,16,14,12,10,8,10,13,16,19,22,25,22,19,16,13,10,8,6]::numeric[]              -- 쌍봉
  when 6 then array[10,10,9.5,9.5,9,9,8.5,8.5,8,8,7.5,7.5,7,7,6.5,6.5,6,6,5.5,5.5,5,8,12,16,20]::numeric[]          -- 함정
  when 7 then array[10,10.5,11,11.5,12,12.5,13,13.5,14,14.5,15,10,6,4,3.5,4,7,11,15,18,16,13,15,18,21]::numeric[]  -- 롤러코스터
  when 8 then array[10,10,10.2,10,16,7,10,10,10.2,10,10,17,6,10,10,10.3,10,10,18,5,10,10,10.2,10,10]::numeric[]      -- 심전도
  else        array[10,9,8,7,6,5,4.5,4,3.5,3,3,3,3,3.5,4,5,6,7,8,9.5,11,12.5,14,15.5,17]::numeric[]                 -- (옛 U자)
end $$;

create or replace function public.ms_rule_def(s text, p jsonb) returns jsonb language plpgsql immutable set search_path = public as $$
declare rd jsonb := p->'rules'->s; m text := rd->>'m';
begin
  return case m
    when 'hold_inv' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('보유 총량이', 2), ms_jt('늘어난 만큼', 3), ms_jt('1주당', 1),
      ms_jt('-' || ms_fmt((rd->>'A')::int) || '원,', 2), ms_jt('줄어든 만큼', 3), ms_jt('1주당', 1), ms_jt('+' || ms_fmt((rd->>'A')::int) || '원', 2))
    when 'follow' then jsonb_build_array(ms_jt((rd->>'R') || '의', 3), ms_jt('가격이', 1),
      ms_jt(case when rd->>'dir' = 'up' then '올랐으면' else '내렸으면' end, 3), ms_jt('+' || (rd->>'B') || '%,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || (rd->>'C') || '%', 2))
    when 'band' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('보유 총량이', 2), ms_jt((rd->>'L') || '주 이상', 3), ms_jt((rd->>'H') || '주 이하이면', 3),
      ms_jt('+' || ms_fmt((rd->>'D')::int) || '원,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || ms_fmt((rd->>'D')::int) || '원', 2))
    when 'buy_vs' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('매수량이', 2), ms_jt((rd->>'R') || '의', 3), ms_jt('매수량보다', 1), ms_jt('많으면', 3),
      ms_jt('+' || ms_fmt((rd->>'E')::int) || '원,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || ms_fmt((rd->>'F')::int) || '원', 2))
    when 'secret' then jsonb_build_array(ms_jt((rd->>'R') || '에', 3), ms_jt('시크릿이', 3), ms_jt('걸려 있으면', 1),
      ms_jt('+' || (rd->>'G') || '%,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || ms_fmt((rd->>'K')::int) || '원', 2))
    when 'mood' then jsonb_build_array(ms_jt('나머지', 0), ms_jt('6종목 중', 1), ms_jt('4개 이상이', 2), ms_jt('상승하면', 3), ms_jt('다음 라운드', 2),
      ms_jt('+' || (rd->>'M') || '%,', 2), ms_jt('2개 이하가', 2), ms_jt('상승하면', 1), ms_jt('다음 라운드', 1), ms_jt('-10%', 2), ms_jt('(3개면 변동 없음)', 0))
    when 'shape' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('주가 그래프는', 2), ms_jt(rd->>'shape_name', 3), ms_jt('모양을', 1), ms_jt('그린다', 1))
    when 'contra' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('매도량이', 3), ms_jt('매수량보다', 1), ms_jt('많으면', 2),
      ms_jt('+' || (rd->>'P') || '%,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || (rd->>'Q') || '%', 2))
    when 'few' then jsonb_build_array(ms_jt(s, 0), ms_jt('보유자가', 2), ms_jt((rd->>'N') || '명 이하이면', 3),
      ms_jt('+' || ms_fmt((rd->>'D')::int) || '원,', 2), ms_jt('그렇지 않으면', 0), ms_jt('-' || ms_fmt((rd->>'D')::int) || '원', 2))
    when 'revert' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('가격이', 1), ms_jt(ms_fmt((rd->>'T')::int) || '원보다', 3), ms_jt('낮으면', 2),
      ms_jt('+' || (rd->>'X') || '%,', 2), ms_jt('높거나 같으면', 1), ms_jt('-' || (rd->>'X') || '%', 2))
    -- v5 신규
    when 'hot' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('매수량이', 2), ms_jt('전체 종목 중', 1), ms_jt('1위면', 3),
      ms_jt('-' || (rd->>'X') || '%,', 2), ms_jt('그렇지 않으면', 0), ms_jt('+' || ms_fmt((rd->>'Y')::int) || '원', 2))
    when 'lonely' then jsonb_build_array(ms_jt('이번 라운드', 0), ms_jt(s, 0), ms_jt('거래가', 2), ms_jt('하나도 없으면', 3),
      ms_jt('+' || (rd->>'X') || '%,', 2), ms_jt('거래가 있으면', 1), ms_jt('-' || ms_fmt((rd->>'Y')::int) || '원', 2))
    when 'parity' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('보유 총량이', 2), ms_jt('홀수면', 3),
      ms_jt('+' || ms_fmt((rd->>'X')::int) || '원,', 2), ms_jt('짝수면', 2), ms_jt('-' || ms_fmt((rd->>'X')::int) || '원', 2))
    when 'monopoly' then jsonb_build_array(ms_jt(s || '의', 0), ms_jt('보유 총량', 1), ms_jt('절반 이상을', 3), ms_jt('한 사람이 가지면', 2),
      ms_jt('-' || (rd->>'X') || '%,', 2), ms_jt('그렇지 않으면', 0), ms_jt('+' || ms_fmt((rd->>'Y')::int) || '원', 2))
    when 'streak' then jsonb_build_array(ms_jt(s || '가', 0), ms_jt((rd->>'N') || '라운드 연속', 3), ms_jt('오르면', 1), ms_jt('그다음 라운드', 1),
      ms_jt('-' || (rd->>'Z') || '%,', 2), ms_jt('그 외에는', 0), ms_jt('+' || ms_fmt((rd->>'Y')::int) || '원', 2))
    when 'cycle' then jsonb_build_array(ms_jt(s || '는', 0), ms_jt('라운드 번호가', 1), ms_jt((rd->>'K') || '의 배수면', 3),
      ms_jt('+' || (rd->>'X') || '%,', 2), ms_jt('아니면', 0), ms_jt('-' || ms_fmt((rd->>'Y')::int) || '원', 2))
  end;
end $$;

create or replace function public.start_game(p_player uuid, p_secret uuid) returns void language plpgsql security definer set search_path = public as $$
declare
  me players; r rooms; n int; p jsonb; rules jsonb := '{}'; m jsonb := '{}'; s text; mech text; i int;
  chosen text[]; sh text[]; shp int; sc numeric; alt jsonb; rd jsonb; other text; lo int;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception '방장만 시작할 수 있어요'; end if;
  if r.status <> 'lobby' then raise exception '이미 시작된 게임이에요'; end if;
  select count(*) into n from players where room_id = r.id;
  if n < 3 then raise exception '최소 3명이 필요해요'; end if;

  select array_agg(q.x) into chosen from (
    select x from unnest(array['hold_inv','follow','band','buy_vs','secret','mood','shape','contra','few',
                               'hot','lonely','parity','monopoly','streak','cycle']) x order by random() limit 7) q;
  select array_agg(x order by random()) into sh from unnest(ms_stocks()) x;

  for i in 1..7 loop
    s := sh[i]; mech := chosen[i];
    select x into other from unnest(ms_stocks()) x where x <> s order by random() limit 1;
    lo := greatest(1, round(n * (0.5 + random())))::int;
    rd := case mech
      when 'hold_inv' then jsonb_build_object('A', (array[200, 250, 300])[1 + floor(random() * 3)::int])
      when 'follow'   then jsonb_build_object('R', other, 'dir', case when random() < 0.5 then 'up' else 'down' end,
                             'B', 8 + floor(random() * 5)::int, 'C', 8 + floor(random() * 5)::int)
      when 'band'     then jsonb_build_object('L', lo, 'H', lo + greatest(2, round(n * (1.5 + random())))::int, 'D', 1000 + 100 * floor(random() * 6)::int)
      when 'buy_vs'   then jsonb_build_object('R', other, 'E', 1200 + 100 * floor(random() * 5)::int, 'F', 600 + 100 * floor(random() * 4)::int)
      when 'secret'   then jsonb_build_object('R', other, 'G', 12 + floor(random() * 4)::int, 'K', 700 + 100 * floor(random() * 4)::int)
      when 'mood'     then jsonb_build_object('M', 15 + floor(random() * 6)::int)
      when 'contra'   then jsonb_build_object('P', 10 + floor(random() * 6)::int, 'Q', 5 + floor(random() * 4)::int)
      when 'few'      then jsonb_build_object('N', greatest(1, round(n * (0.25 + random() * 0.25)))::int, 'D', 1000 + 100 * floor(random() * 6)::int)
      when 'hot'      then jsonb_build_object('X', 10 + floor(random() * 6)::int, 'Y', 600 + 100 * floor(random() * 5)::int)
      when 'lonely'   then jsonb_build_object('X', 8 + floor(random() * 5)::int, 'Y', 600 + 100 * floor(random() * 5)::int)
      when 'parity'   then jsonb_build_object('X', 800 + 100 * floor(random() * 8)::int)
      when 'monopoly' then jsonb_build_object('X', 10 + floor(random() * 6)::int, 'Y', 500 + 100 * floor(random() * 5)::int)
      when 'streak'   then jsonb_build_object('N', 2 + floor(random() * 2)::int, 'Z', 15 + floor(random() * 11)::int, 'Y', 300 + 100 * floor(random() * 5)::int)
      when 'cycle'    then jsonb_build_object('K', 3 + floor(random() * 3)::int, 'X', 15 + floor(random() * 11)::int, 'Y', 400 + 100 * floor(random() * 5)::int)
      else '{}'::jsonb
    end;
    if mech = 'shape' then
      shp := 1 + floor(random() * 8)::int;
      sc := round((0.8 + random() * 0.4)::numeric, 2);
      rd := jsonb_build_object('shape', shp, 'shape_name', (array['W', 'M', '계단', '번개', '쌍봉', '함정', '롤러코스터', '심전도'])[shp], 'scale', sc);
      select jsonb_agg(ms_r10(10000 + (u.v - 10) * 1000 * sc) order by u.o) into alt from unnest(ms_shape(shp)) with ordinality as u(v, o);
    end if;
    rules := rules || jsonb_build_object(s, rd || jsonb_build_object('m', mech));
  end loop;
  p := jsonb_build_object('v', 5, 'n', n, 'rules', rules);

  foreach s in array ms_stocks() loop
    m := m || jsonb_build_object(s, (select jsonb_agg(x.o order by (x.e->>'w')::int desc, random())
                                     from jsonb_array_elements(ms_rule_def(s, p)) with ordinality as x(e, o)));
  end loop;

  update rooms set status = 'playing', round = 1, params = p, masks = m, alt_path = alt,
    prices = (select jsonb_object_agg(x, 10000) from unnest(ms_stocks()) x),
    prev_hold = ms_zero(), round_buy = ms_zero(), round_sell = ms_zero(), mat_next = 0,
    round_started_at = now(), countdown_end = null, countdown_reason = null
  where id = r.id;
  insert into history(room_id, round, data) values (r.id, 0, jsonb_build_object(
    'prices', (select jsonb_object_agg(x, 10000) from unnest(ms_stocks()) x),
    'change', ms_zero(), 'buy', ms_zero(), 'sell', ms_zero(), 'hold', ms_zero(), 'holders', ms_zero()));
  insert into asset_history(room_id, round, player_id, asset) select r.id, 0, pl.id, 100000 from players pl where pl.room_id = r.id;
  -- 방장이 정한 개수가 있으면 그 값, 없으면(자동) 인원별 기준
  update players set last_seen = now(),
       tokens  = coalesce(r.cfg_tokens,  case when n < 5 then 3 when n < 10 then 2 else 1 end),
       secrets = coalesce(r.cfg_secrets, case when n < 5 then 2 else 1 end),
       blind_used = coalesce(r.cfg_secrets, 1) = 0
     where room_id = r.id;
  insert into events(room_id, round, msg) values (r.id, 1, '거래소 개장! 24라운드 동안 숨겨진 규칙을 추리하세요');
end $$;

create or replace function public.ms_resolve(rid uuid) returns void language plpgsql security definer set search_path = public as $$
declare
  r rooms; prm jsonb; t int; pr jsonb; nw jsonb := '{}'; hn jsonb := '{}'; hp jsonb; bu jsonb; se jsonb;
  chg jsonb := '{}'; s text; v numeric; hv int; ups int := 0; cond boolean; matp numeric := 0;
  rd jsonb; mech text; cur numeric; cnt int; mood_s text; rs text; mx int;
begin
  select * into r from rooms where id = rid and status = 'playing'
    and countdown_end is not null and countdown_end <= now() for update;
  if not found then return; end if;
  prm := r.params; t := r.round; pr := r.prices; hp := r.prev_hold; bu := r.round_buy; se := r.round_sell;

  foreach s in array ms_stocks() loop
    select coalesce(sum(qty), 0) into hv from holdings where room_id = rid and stock = s;
    hn := hn || jsonb_build_object(s, hv);
  end loop;

  -- 1단계: follow 제외 전부
  foreach s in array ms_stocks() loop
    rd := prm->'rules'->s; mech := rd->>'m'; cur := (pr->>s)::numeric; rs := rd->>'R';
    continue when mech = 'follow';
    if mech = 'hold_inv' then
      v := cur - (rd->>'A')::int * ((hn->>s)::int - (hp->>s)::int);
    elsif mech = 'band' then
      v := case when (hn->>s)::int between (rd->>'L')::int and (rd->>'H')::int then cur + (rd->>'D')::int else cur - (rd->>'D')::int end;
    elsif mech = 'buy_vs' then
      v := case when coalesce((bu->>s)::int, 0) > coalesce((bu->>rs)::int, 0) then cur + (rd->>'E')::int else cur - (rd->>'F')::int end;
    elsif mech = 'secret' then
      if exists (select 1 from blinds b where b.room_id = rid and b.stock = rs and t between b.start_round and b.end_round)
        then v := cur * (1 + (rd->>'G')::numeric / 100); else v := cur - (rd->>'K')::int; end if;
    elsif mech = 'mood' then
      v := cur * (1 + r.mat_next); mood_s := s;
    elsif mech = 'shape' then
      v := (r.alt_path->>t)::numeric;
    elsif mech = 'contra' then
      v := case when coalesce((se->>s)::int, 0) > coalesce((bu->>s)::int, 0)
                then cur * (1 + (rd->>'P')::numeric / 100) else cur * (1 - (rd->>'Q')::numeric / 100) end;
    elsif mech = 'few' then
      select count(*) into cnt from holdings h where h.room_id = rid and h.stock = s and h.qty > 0;
      v := case when cnt <= (rd->>'N')::int then cur + (rd->>'D')::int else cur - (rd->>'D')::int end;
    elsif mech = 'revert' then
      v := case when cur < (rd->>'T')::int then cur * (1 + (rd->>'X')::numeric / 100) else cur * (1 - (rd->>'X')::numeric / 100) end;
    elsif mech = 'hot' then
      -- 매수량 1위(동률 포함, 0주는 제외)면 하락
      select coalesce(max(e.value::int), 0) into mx from jsonb_each_text(bu) e where e.key <> s;
      v := case when coalesce((bu->>s)::int, 0) > 0 and coalesce((bu->>s)::int, 0) >= mx
                then cur * (1 - (rd->>'X')::numeric / 100) else cur + (rd->>'Y')::int end;
    elsif mech = 'lonely' then
      v := case when coalesce((bu->>s)::int, 0) + coalesce((se->>s)::int, 0) = 0
                then cur * (1 + (rd->>'X')::numeric / 100) else cur - (rd->>'Y')::int end;
    elsif mech = 'parity' then
      v := case when (hn->>s)::int % 2 = 1 then cur + (rd->>'X')::int else cur - (rd->>'X')::int end;
    elsif mech = 'monopoly' then
      select coalesce(max(h.qty), 0) into mx from holdings h where h.room_id = rid and h.stock = s;
      v := case when (hn->>s)::int > 0 and mx * 2 >= (hn->>s)::int
                then cur * (1 - (rd->>'X')::numeric / 100) else cur + (rd->>'Y')::int end;
    elsif mech = 'streak' then
      -- 직전 N라운드가 모두 상승이면 이번 라운드 폭락
      select count(*) into cnt from history h
        where h.room_id = rid and h.round between t - (rd->>'N')::int and t - 1 and h.round >= 1
          and (h.data->'change'->>s)::int > 0;
      v := case when cnt >= (rd->>'N')::int then cur * (1 - (rd->>'Z')::numeric / 100) else cur + (rd->>'Y')::int end;
    elsif mech = 'cycle' then
      v := case when t % (rd->>'K')::int = 0 then cur * (1 + (rd->>'X')::numeric / 100) else cur - (rd->>'Y')::int end;
    else
      v := cur;
    end if;
    nw := nw || jsonb_build_object(s, ms_r10(v));
  end loop;

  -- 2단계: follow (참조 종목의 이번 라운드 결과 사용)
  foreach s in array ms_stocks() loop
    rd := prm->'rules'->s;
    continue when coalesce(rd->>'m', '') <> 'follow';
    rs := rd->>'R'; cur := (pr->>s)::numeric;
    if rd->>'dir' = 'up' then cond := (nw->>rs)::int > (pr->>rs)::int; else cond := (nw->>rs)::int < (pr->>rs)::int; end if;
    v := case when cond then cur * (1 + (rd->>'B')::numeric / 100) else cur * (1 - (rd->>'C')::numeric / 100) end;
    nw := nw || jsonb_build_object(s, ms_r10(v));
  end loop;

  foreach s in array ms_stocks() loop
    if s is distinct from mood_s and (nw->>s)::int > (pr->>s)::int then ups := ups + 1; end if;
    chg := chg || jsonb_build_object(s, (nw->>s)::int - (pr->>s)::int);
  end loop;
  if mood_s is not null then
    matp := case when ups >= 4 then (prm->'rules'->mood_s->>'M')::numeric / 100 when ups <= 2 then -0.10 else 0 end;
  end if;

  insert into history(room_id, round, data) values (rid, t,
    jsonb_build_object('prices', nw, 'change', chg, 'buy', bu, 'sell', se, 'hold', hn,
      'holders', (select jsonb_object_agg(x, (select count(*) from holdings h2 where h2.room_id = rid and h2.stock = x and h2.qty > 0)) from unnest(ms_stocks()) x)));
  insert into asset_history(room_id, round, player_id, asset)
    select rid, t, pl.id, pl.cash + coalesce((select sum(h.qty::bigint * (nw->>h.stock)::bigint) from holdings h where h.player_id = pl.id), 0)
    from players pl where pl.room_id = rid;

  update rooms set prices = nw, prev_hold = hn, round_buy = ms_zero(), round_sell = ms_zero(), mat_next = matp,
    round = case when t >= 24 then 24 else t + 1 end,
    status = case when t >= 24 then 'finished' else 'playing' end,
    round_started_at = now(), countdown_end = null, countdown_reason = null
  where id = rid;
  update players set end_vote = false where room_id = rid;

  if t >= 24 then
    insert into events(room_id, round, msg) values (rid, 24, '거래 종료! 최종 결과를 확인하세요');
  elsif ms_stage(t + 1) > ms_stage(t) then
    insert into events(room_id, round, msg) values (rid, t + 1,
      case when t + 1 = 20 then '20라운드: 모든 규칙이 공개되었습니다' else (t + 1) || '라운드: 규칙 일부가 새로 공개되었습니다' end);
  end if;
end $$;

revoke execute on function public.ms_shape(int), public.ms_rule_def(text, jsonb), public.ms_resolve(uuid) from public, anon, authenticated;
revoke execute on function public.start_game(uuid, uuid) from public;
grant execute on function public.start_game(uuid, uuid) to anon, authenticated;
