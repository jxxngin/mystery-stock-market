-- 미스터리 주식 시장 : Supabase schema
-- 모든 게임 로직은 SECURITY DEFINER 함수(RPC)에서만 실행된다. 테이블은 RLS로 직접 접근 차단.

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  status text not null default 'lobby',          -- lobby | playing | finished
  round int not null default 0,
  host_id uuid,
  params jsonb,                                   -- 판마다 랜덤인 규칙 값 (비공개)
  masks jsonb,                                    -- 종목별 단어 가림 순서 (비공개)
  alt_path jsonb,                                 -- 알트엔터 가격 경로 (비공개)
  prices jsonb,                                   -- 현재가
  prev_hold jsonb,                                -- 직전 라운드 종료 시 보유 총량
  round_buy jsonb,
  round_sell jsonb,
  mat_next numeric not null default 0,            -- 맛소금융 다음 라운드 변동률
  round_started_at timestamptz,
  countdown_end timestamptz,
  countdown_reason text,
  created_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  secret uuid not null default gen_random_uuid(),
  cash bigint not null default 100000,
  tokens int not null default 2,
  blind_used boolean not null default false,
  end_vote boolean not null default false,
  peeks jsonb not null default '{}',
  last_seen timestamptz not null default now(),
  joined_at timestamptz not null default now()
);
create index on public.players(room_id);

create table public.holdings (
  player_id uuid not null references public.players(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  stock text not null,
  qty int not null default 0,
  primary key (player_id, stock)
);
create index on public.holdings(room_id, stock);

create table public.blinds (
  id bigserial primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  stock text not null,
  start_round int not null,
  end_round int not null
);
create index on public.blinds(room_id);

create table public.history (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round int not null,
  data jsonb not null,
  primary key (room_id, round)
);

create table public.asset_history (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round int not null,
  player_id uuid not null references public.players(id) on delete cascade,
  asset bigint not null,
  primary key (room_id, round, player_id)
);
create index on public.asset_history(player_id);

create table public.events (
  id bigserial primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  round int,
  msg text not null,
  created_at timestamptz not null default now()
);
create index on public.events(room_id);

alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.holdings enable row level security;
alter table public.blinds enable row level security;
alter table public.history enable row level security;
alter table public.asset_history enable row level security;
alter table public.events enable row level security;
revoke all on public.rooms, public.players, public.holdings, public.blinds,
  public.history, public.asset_history, public.events from anon, authenticated;

-- ───────── helpers ─────────
create or replace function public.ms_stocks() returns text[] language sql immutable set search_path = public as
$$ select array['맛소금융','무조건설','방어제철','알트엔터','열림보안','코요테크','후자전자'] $$;

create or replace function public.ms_zero() returns jsonb language sql immutable set search_path = public as
$$ select jsonb_object_agg(x, 0) from unnest(public.ms_stocks()) x $$;

create or replace function public.ms_r10(v numeric) returns int language sql immutable set search_path = public as
$$ select greatest(100, round(v / 10.0) * 10)::int $$;

create or replace function public.ms_fmt(v int) returns text language sql immutable set search_path = public as
$$ select to_char(v, 'FM999,999,999') $$;

create or replace function public.ms_stage(rnd int) returns int language sql immutable set search_path = public as
$$ select case when rnd >= 20 then 4 when rnd >= 15 then 3 when rnd >= 10 then 2 when rnd >= 5 then 1 else 0 end $$;

-- 알트엔터 모양 (25개 지점, 단위: 천원)
create or replace function public.ms_shape(idx int) returns numeric[] language sql immutable set search_path = public as $$
select case idx
  when 1 then array[10,9,8,7,6,5,6.5,8,9.5,11,12,11,10,9,8,7,8,9.5,11,12.5,14,15,16,17,18]::numeric[]          -- W
  when 2 then array[10,11.5,13,14.5,16,17.5,16,14.5,13,11.5,10,11.5,13,14.5,16,17.5,16,14,12,10,8,6.5,5,4,3]::numeric[] -- M
  when 3 then array[10,10,12,12,12,14,14,14,16,16,16,18,18,18,16,16,18,20,20,20,22,22,22,24,24]::numeric[]        -- 계단
  when 4 then array[10,13,8,11,6,9,4,7,3,6,2,5,8,4,7,10,6,9,12,8,11,14,10,13,16]::numeric[]                    -- 번개
  when 5 then array[10,12,14,16,18,20,18,16,14,12,10,8,10,13,16,19,22,25,22,19,16,13,10,8,6]::numeric[]        -- 쌍봉
  else        array[10,9,8,7,6,5,4.5,4,3.5,3,3,3,3,3.5,4,5,6,7,8,9.5,11,12.5,14,15.5,17]::numeric[]             -- U자
end $$;

create or replace function public.ms_rule_tokens(s text, p jsonb) returns text[] language plpgsql immutable set search_path = public as $$
begin
  return case s
    when '방어제철' then array['방어제철의','보유 총량이','증가한 만큼','1주당','-' || ms_fmt((p->>'A')::int) || '원,','감소한 만큼','1주당','+' || ms_fmt((p->>'A')::int) || '원']
    when '무조건설' then array['방어제철의','가격이', case when p->>'dir' = 'up' then '올랐으면' else '내렸으면' end, '+' || (p->>'B') || '%,','그렇지 않으면','-' || (p->>'C') || '%']
    when '후자전자' then array['후자전자의','보유 총량이',(p->>'L') || '주 이상',(p->>'H') || '주 이하이면','+' || ms_fmt((p->>'D')::int) || '원,','그렇지 않으면','-' || ms_fmt((p->>'D')::int) || '원']
    when '코요테크' then array['코요테크의','매수량이',(p->>'X') || '의','매수량보다','많으면','+' || ms_fmt((p->>'E')::int) || '원,','그렇지 않으면','-' || ms_fmt((p->>'F')::int) || '원']
    when '열림보안' then array[(p->>'Y') || '에','시크릿이','걸려 있으면','+' || (p->>'G') || '%,','그렇지 않으면','-' || ms_fmt((p->>'K')::int) || '원']
    when '맛소금융' then array['나머지','6종목 중','4개 이상이','상승하면','다음 라운드','+' || (p->>'M') || '%,','2개 이하가','상승하면','다음 라운드','-10%','(3개면 변동 없음)']
    when '알트엔터' then array['알트엔터의','주가 그래프는',(p->>'shape_name'),'모양을','그린다']
  end;
end $$;

create or replace function public.ms_rule_view(s text, p jsonb, m jsonb, lvl int) returns text language plpgsql stable set search_path = public as $$
declare
  toks text[] := ms_rule_tokens(s, p);
  n int := array_length(toks, 1);
  fr numeric[] := array[0.8, 0.6, 0.4, 0.2, 0];
  h int;
  hid int[];
  outp text[] := '{}';
  i int;
begin
  h := round(n * fr[least(greatest(lvl, 0), 4) + 1]);
  select coalesce(array_agg(e.v::int), '{}') into hid
    from jsonb_array_elements_text(m->s) with ordinality as e(v, ord) where e.ord <= h;
  for i in 1..n loop
    if i = any(hid) then outp := outp || regexp_replace(toks[i], '\S', '□', 'g');
    else outp := outp || toks[i]; end if;
  end loop;
  return array_to_string(outp, ' ');
end $$;

-- 단어별 상태: open(공개) / peek(토큰으로 미리 봄) / next(다음 공개 단계에서 열림) / hidden
create or replace function public.ms_rule_parts(s text, p jsonb, m jsonb, lvl int, stg int) returns jsonb language plpgsql stable set search_path = public as $$
declare
  toks text[] := ms_rule_tokens(s, p);
  n int := array_length(toks, 1);
  fr numeric[] := array[0.8, 0.6, 0.4, 0.2, 0];
  h_lvl int; h_next int; h_stg int; o int; i int;
  outp jsonb := '[]';
begin
  h_lvl  := round(n * fr[least(greatest(lvl, 0), 4) + 1]);
  h_next := round(n * fr[least(greatest(lvl, 0) + 1, 4) + 1]);
  h_stg  := round(n * fr[least(greatest(stg, 0), 4) + 1]);
  for i in 1..n loop
    select e.ord into o from jsonb_array_elements_text(m->s) with ordinality as e(v, ord) where e.v::int = i;
    if o <= h_lvl then
      outp := outp || jsonb_build_array(jsonb_build_object('t', regexp_replace(toks[i], '\S', '□', 'g'),
                'k', case when o > h_next then 'next' else 'hidden' end));
    else
      outp := outp || jsonb_build_array(jsonb_build_object('t', toks[i],
                'k', case when o <= h_stg then 'peek' else 'open' end));
    end if;
  end loop;
  return outp;
end $$;

create or replace function public.ms_auth(p_player uuid, p_secret uuid) returns public.players language plpgsql security definer set search_path = public as $$
declare me players;
begin
  select * into me from players where id = p_player and secret = p_secret;
  if not found then raise exception '인증 실패: 다시 입장해주세요'; end if;
  return me;
end $$;

-- ───────── 라운드 정산 ─────────
create or replace function public.ms_resolve(rid uuid) returns void language plpgsql security definer set search_path = public as $$
declare
  r rooms; prm jsonb; t int; pr jsonb; nw jsonb := '{}'; hn jsonb := '{}'; hp jsonb; bu jsonb; se jsonb;
  chg jsonb := '{}'; s text; v numeric; hv int; ups int := 0; cond boolean; matp numeric;
begin
  select * into r from rooms where id = rid and status = 'playing'
    and countdown_end is not null and countdown_end <= now() for update;
  if not found then return; end if;
  prm := r.params; t := r.round; pr := r.prices; hp := r.prev_hold; bu := r.round_buy; se := r.round_sell;

  foreach s in array ms_stocks() loop
    select coalesce(sum(qty), 0) into hv from holdings where room_id = rid and stock = s;
    hn := hn || jsonb_build_object(s, hv);
  end loop;

  -- 방어제철
  v := (pr->>'방어제철')::numeric - (prm->>'A')::int * ((hn->>'방어제철')::int - (hp->>'방어제철')::int);
  nw := nw || jsonb_build_object('방어제철', ms_r10(v));
  -- 후자전자
  hv := (hn->>'후자전자')::int;
  if hv between (prm->>'L')::int and (prm->>'H')::int then v := (pr->>'후자전자')::numeric + (prm->>'D')::int;
  else v := (pr->>'후자전자')::numeric - (prm->>'D')::int; end if;
  nw := nw || jsonb_build_object('후자전자', ms_r10(v));
  -- 코요테크
  if coalesce((bu->>'코요테크')::int, 0) > coalesce((bu->>(prm->>'X'))::int, 0) then v := (pr->>'코요테크')::numeric + (prm->>'E')::int;
  else v := (pr->>'코요테크')::numeric - (prm->>'F')::int; end if;
  nw := nw || jsonb_build_object('코요테크', ms_r10(v));
  -- 열림보안
  if exists (select 1 from blinds b where b.room_id = rid and b.stock = prm->>'Y' and t between b.start_round and b.end_round) then
    v := (pr->>'열림보안')::numeric * (1 + (prm->>'G')::numeric / 100);
  else v := (pr->>'열림보안')::numeric - (prm->>'K')::int; end if;
  nw := nw || jsonb_build_object('열림보안', ms_r10(v));
  -- 알트엔터
  nw := nw || jsonb_build_object('알트엔터', ms_r10((r.alt_path->>t)::numeric));
  -- 무조건설 (방어제철 결과 사용)
  if prm->>'dir' = 'up' then cond := (nw->>'방어제철')::int > (pr->>'방어제철')::int;
  else cond := (nw->>'방어제철')::int < (pr->>'방어제철')::int; end if;
  if cond then v := (pr->>'무조건설')::numeric * (1 + (prm->>'B')::numeric / 100);
  else v := (pr->>'무조건설')::numeric * (1 - (prm->>'C')::numeric / 100); end if;
  nw := nw || jsonb_build_object('무조건설', ms_r10(v));
  -- 맛소금융 (지난 라운드에 정해진 변동률 적용)
  nw := nw || jsonb_build_object('맛소금융', ms_r10((pr->>'맛소금융')::numeric * (1 + r.mat_next)));

  foreach s in array ms_stocks() loop
    if s <> '맛소금융' and (nw->>s)::int > (pr->>s)::int then ups := ups + 1; end if;
    chg := chg || jsonb_build_object(s, (nw->>s)::int - (pr->>s)::int);
  end loop;
  matp := case when ups >= 4 then (prm->>'M')::numeric / 100 when ups <= 2 then -0.10 else 0 end;

  insert into history(room_id, round, data) values (rid, t,
    jsonb_build_object('prices', nw, 'change', chg, 'buy', bu, 'sell', se, 'hold', hn));
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
  else
    if ms_stage(t + 1) > ms_stage(t) then
      insert into events(room_id, round, msg) values (rid, t + 1,
        case when t + 1 = 20 then '20라운드: 모든 규칙이 공개되었습니다' else (t + 1) || '라운드: 규칙 일부가 새로 공개되었습니다' end);
    end if;
  end if;
end $$;

create or replace function public.ms_tick(rid uuid) returns void language plpgsql security definer set search_path = public as $$
declare r rooms; act int; vts int; need int;
begin
  select * into r from rooms where id = rid;
  if r.status <> 'playing' then return; end if;
  select count(*), count(*) filter (where end_vote) into act, vts
    from players where room_id = rid and last_seen > now() - interval '15 seconds';
  need := greatest(1, ceil(act * 0.7))::int;
  if r.countdown_end is null then
    if act > 0 and vts >= need then
      update rooms set countdown_end = now() + make_interval(secs => 5 + random() * 5), countdown_reason = 'vote'
        where id = rid and countdown_end is null and round = r.round;
    elsif now() > r.round_started_at + interval '180 seconds' then
      update rooms set countdown_end = now() + make_interval(secs => 5 + random() * 5), countdown_reason = 'timeout'
        where id = rid and countdown_end is null and round = r.round;
    end if;
  elsif now() >= r.countdown_end then
    perform ms_resolve(rid);
  elsif r.countdown_reason = 'vote' and vts < need then
    update rooms set countdown_end = null, countdown_reason = null
      where id = rid and round = r.round and countdown_reason = 'vote';
  end if;
end $$;

-- ───────── public RPC ─────────
create or replace function public.create_room(p_name text) returns jsonb language plpgsql security definer set search_path = public as $$
declare c text; rid uuid; pl players; chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ'; i int;
begin
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' or char_length(p_name) > 12 then raise exception '이름은 1~12자로 입력해주세요'; end if;
  loop
    c := '';
    for i in 1..4 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from rooms where code = c);
  end loop;
  insert into rooms(code) values (c) returning id into rid;
  insert into players(room_id, name) values (rid, p_name) returning * into pl;
  update rooms set host_id = pl.id where id = rid;
  return jsonb_build_object('player_id', pl.id, 'secret', pl.secret, 'code', c);
end $$;

create or replace function public.join_room(p_code text, p_name text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r rooms; pl players; cnt int;
begin
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' or char_length(p_name) > 12 then raise exception '이름은 1~12자로 입력해주세요'; end if;
  select * into r from rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception '존재하지 않는 방 코드예요'; end if;
  if r.status <> 'lobby' then raise exception '이미 시작된 방이에요'; end if;
  select count(*) into cnt from players where room_id = r.id;
  if cnt >= 12 then raise exception '방이 가득 찼어요 (최대 12명)'; end if;
  if exists (select 1 from players where room_id = r.id and name = p_name) then raise exception '이미 사용 중인 이름이에요'; end if;
  insert into players(room_id, name) values (r.id, p_name) returning * into pl;
  return jsonb_build_object('player_id', pl.id, 'secret', pl.secret, 'code', r.code);
end $$;

create or replace function public.start_game(p_player uuid, p_secret uuid) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms; n int; p jsonb; m jsonb := '{}'; s text; ln int; shp int; sc numeric; alt jsonb; lo int;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception '방장만 시작할 수 있어요'; end if;
  if r.status <> 'lobby' then raise exception '이미 시작된 게임이에요'; end if;
  select count(*) into n from players where room_id = r.id;
  if n < 3 then raise exception '최소 3명이 필요해요'; end if;

  shp := 1 + floor(random() * 6)::int;
  sc := round((0.8 + random() * 0.4)::numeric, 2);
  lo := greatest(1, round(n * (0.5 + random())))::int;
  p := jsonb_build_object(
    'A', (array[200, 250, 300])[1 + floor(random() * 3)::int],
    'dir', case when random() < 0.5 then 'up' else 'down' end,
    'B', 8 + floor(random() * 5)::int, 'C', 8 + floor(random() * 5)::int,
    'L', lo, 'H', lo + greatest(2, round(n * (1.5 + random())))::int,
    'D', 1000 + 100 * floor(random() * 6)::int,
    'X', (array['열림보안', '후자전자', '알트엔터'])[1 + floor(random() * 3)::int],
    'E', 1200 + 100 * floor(random() * 5)::int, 'F', 600 + 100 * floor(random() * 4)::int,
    'Y', (array['무조건설', '후자전자', '방어제철'])[1 + floor(random() * 3)::int],
    'G', 12 + floor(random() * 4)::int, 'K', 700 + 100 * floor(random() * 4)::int,
    'M', 15 + floor(random() * 6)::int,
    'shape', shp, 'shape_name', (array['W', 'M', '계단', '번개', '쌍봉', 'U자'])[shp], 'scale', sc, 'n', n);

  foreach s in array ms_stocks() loop
    ln := array_length(ms_rule_tokens(s, p), 1);
    m := m || jsonb_build_object(s, (select jsonb_agg(g order by random()) from generate_series(1, ln) g));
  end loop;
  select jsonb_agg(ms_r10(10000 + (u.v - 10) * 1000 * sc) order by u.o) into alt
    from unnest(ms_shape(shp)) with ordinality as u(v, o);

  update rooms set status = 'playing', round = 1, params = p, masks = m, alt_path = alt,
    prices = (select jsonb_object_agg(x, 10000) from unnest(ms_stocks()) x),
    prev_hold = ms_zero(), round_buy = ms_zero(), round_sell = ms_zero(), mat_next = 0,
    round_started_at = now(), countdown_end = null, countdown_reason = null
  where id = r.id;
  insert into history(room_id, round, data) values (r.id, 0, jsonb_build_object(
    'prices', (select jsonb_object_agg(x, 10000) from unnest(ms_stocks()) x),
    'change', ms_zero(), 'buy', ms_zero(), 'sell', ms_zero(), 'hold', ms_zero()));
  insert into asset_history(room_id, round, player_id, asset) select r.id, 0, pl.id, 100000 from players pl where pl.room_id = r.id;
  update players set last_seen = now() where room_id = r.id;
  insert into events(room_id, round, msg) values (r.id, 1, '거래소 개장! 24라운드 동안 숨겨진 규칙을 추리하세요');
end $$;

create or replace function public.trade(p_player uuid, p_secret uuid, p_stock text, p_qty int) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms; price bigint; cur int;
begin
  me := ms_auth(p_player, p_secret);
  if not (p_stock = any(ms_stocks())) then raise exception '없는 종목이에요'; end if;
  if p_qty = 0 or abs(p_qty) > 100000 then raise exception '수량이 올바르지 않아요'; end if;
  select * into r from rooms where id = me.room_id for update;
  if r.status <> 'playing' then raise exception '거래 시간이 아니에요'; end if;
  if r.countdown_end is not null and now() >= r.countdown_end then raise exception '이번 라운드 거래가 마감됐어요'; end if;
  select * into me from players where id = me.id for update;
  price := (r.prices->>p_stock)::bigint;
  if p_qty > 0 then
    if me.cash < price * p_qty then raise exception '현금이 부족해요'; end if;
    update players set cash = cash - price * p_qty where id = me.id;
    insert into holdings(player_id, room_id, stock, qty) values (me.id, r.id, p_stock, p_qty)
      on conflict (player_id, stock) do update set qty = holdings.qty + excluded.qty;
    update rooms set round_buy = jsonb_set(round_buy, array[p_stock], to_jsonb(coalesce((round_buy->>p_stock)::int, 0) + p_qty)) where id = r.id;
  else
    select qty into cur from holdings where player_id = me.id and stock = p_stock;
    if coalesce(cur, 0) < -p_qty then raise exception '보유 주식이 부족해요'; end if;
    update players set cash = cash + price * (-p_qty) where id = me.id;
    update holdings set qty = qty + p_qty where player_id = me.id and stock = p_stock;
    update rooms set round_sell = jsonb_set(round_sell, array[p_stock], to_jsonb(coalesce((round_sell->>p_stock)::int, 0) - p_qty)) where id = r.id;
  end if;
end $$;

create or replace function public.set_vote(p_player uuid, p_secret uuid, p_vote boolean) returns void language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ms_auth(p_player, p_secret);
  update players set end_vote = p_vote, last_seen = now() where id = me.id;
  perform ms_tick(me.room_id);
end $$;

create or replace function public.force_end(p_player uuid, p_secret uuid) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception '방장만 강제 종료할 수 있어요'; end if;
  if r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  update rooms set countdown_end = now() + make_interval(secs => 5 + random() * 5), countdown_reason = 'force'
    where id = r.id and (countdown_end is null or countdown_reason = 'vote');
end $$;

create or replace function public.use_blind(p_player uuid, p_secret uuid, p_stock text) returns void language plpgsql security definer set search_path = public as $$
declare me players; r rooms;
begin
  me := ms_auth(p_player, p_secret);
  if not (p_stock = any(ms_stocks())) then raise exception '없는 종목이에요'; end if;
  select * into r from rooms where id = me.room_id for update;
  if r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  if r.round >= 24 then raise exception '마지막 라운드에는 사용할 수 없어요'; end if;
  if me.blind_used then raise exception '시크릿은 한 번만 사용할 수 있어요'; end if;
  if exists (select 1 from blinds where room_id = r.id and stock = p_stock and start_round = r.round + 1) then
    null; -- 같은 종목에 이미 같은 라운드 시크릿 예약됨: 효과는 한 번만
  elsif exists (select 1 from blinds where room_id = r.id and stock = p_stock
                and (r.round between start_round and end_round or r.round + 1 between start_round and end_round)) then
    raise exception '이미 가려진 종목이에요';
  else
    insert into blinds(room_id, stock, start_round, end_round) values (r.id, p_stock, r.round + 1, r.round + 2);
  end if;
  update players set blind_used = true where id = me.id;
  insert into events(room_id, round, msg) values (r.id, r.round, '누군가 시크릿을 사용했습니다 (다음 라운드부터 2라운드)');
end $$;

create or replace function public.use_token(p_player uuid, p_secret uuid, p_kind text, p_stock text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me players; r rooms; cur int; lvl int;
begin
  me := ms_auth(p_player, p_secret);
  select * into r from rooms where id = me.room_id for update;
  select * into me from players where id = me.id for update;
  if r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  if r.round > 19 then raise exception '정보 토큰은 19라운드까지만 사용할 수 있어요'; end if;
  if me.tokens <= 0 then raise exception '남은 정보 토큰이 없어요'; end if;
  if p_kind = 'cash' then
    update players set cash = cash + 10000, tokens = tokens - 1 where id = me.id;
  elsif p_kind = 'peek' then
    if not (p_stock = any(ms_stocks())) then raise exception '없는 종목이에요'; end if;
    cur := greatest(ms_stage(r.round), coalesce((me.peeks->>p_stock)::int, 0));
    if cur >= 4 then raise exception '이미 전부 보이는 규칙이에요'; end if;
    lvl := cur + 1;
    update players set tokens = tokens - 1, peeks = peeks || jsonb_build_object(p_stock, lvl) where id = me.id;
  else
    raise exception '알 수 없는 사용 방식이에요';
  end if;
  insert into events(room_id, round, msg) values (r.id, r.round, '누군가 정보 토큰을 사용했습니다');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_state(p_player uuid, p_secret uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me players; r rooms; stg int := 0; s text; lastrow jsonb; hidden_now text[] := '{}'; st jsonb := '[]';
  hist jsonb; rk jsonb; pls jsonb; ev jsonb; act int; vts int; fin jsonb; hold jsonb; lvl int; hid boolean; lr int;
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
      lvl := case when r.status = 'finished' then 4 else greatest(stg, coalesce((me.peeks->>s)::int, 0)) end;
      st := st || jsonb_build_array(jsonb_build_object('name', s, 'hidden', hid,
        'price',  case when hid then null else lastrow->'prices'->s end,
        'change', case when hid then null else lastrow->'change'->s end,
        'buy',    case when hid then null else lastrow->'buy'->s end,
        'sell',   case when hid then null else lastrow->'sell'->s end,
        'hold',   case when hid then null else lastrow->'hold'->s end,
        'rule', ms_rule_view(s, r.params, r.masks, lvl), 'parts', ms_rule_parts(s, r.params, r.masks, lvl, stg), 'level', lvl,
        'peeked', coalesce((me.peeks->>s)::int, 0) > stg));
    end loop;

    select jsonb_agg(jsonb_build_object('round', h.round, 'prices',
             (select jsonb_object_agg(k, case when r.status = 'playing' and exists (
                 select 1 from blinds b where b.room_id = r.id and b.stock = k
                   and h.round + 1 between b.start_round and b.end_round and r.round <= b.end_round)
               then null else h.data->'prices'->k end)
              from jsonb_object_keys(h.data->'prices') k)) order by h.round)
      into hist from history h where h.room_id = r.id;

    select coalesce(jsonb_agg(jsonb_build_object('name', pl.name, 'me', pl.id = me.id,
             'asset', case when cardinality(hidden_now) > 0 then null else a.asset end)
             order by a.asset desc, pl.cash desc), '[]')
      into rk from asset_history a join players pl on pl.id = a.player_id where a.room_id = r.id and a.round = lr;

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

-- ───────── 권한 ─────────
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.create_room(text), public.join_room(text, text), public.get_state(uuid, uuid),
  public.start_game(uuid, uuid), public.trade(uuid, uuid, text, int), public.set_vote(uuid, uuid, boolean),
  public.force_end(uuid, uuid), public.use_blind(uuid, uuid, text), public.use_token(uuid, uuid, text, text)
to anon, authenticated;
