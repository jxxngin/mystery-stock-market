-- v4: 인원별 아이템 개수 (v3_state.sql 이후 적용)
--   3~4명: 정보 토큰 3 · 시크릿 2
--   5~9명: 정보 토큰 2 · 시크릿 1
--  10~12명: 정보 토큰 1 · 시크릿 1

alter table public.players add column if not exists secrets int not null default 1;

do $$
declare d text; d2 text;
begin
  -- start_game: 시작 시 인원에 맞춰 아이템 지급
  d := pg_get_functiondef('public.start_game(uuid,uuid)'::regprocedure);
  d2 := replace(d, 'update players set last_seen = now() where room_id = r.id;',
    'update players set last_seen = now(),
       tokens  = case when n < 5 then 3 when n < 10 then 2 else 1 end,
       secrets = case when n < 5 then 2 else 1 end,
       blind_used = false
     where room_id = r.id;');
  if d2 = d then raise exception 'start_game patch failed'; end if;
  execute d2;

  -- use_blind: 남은 개수로 판정
  d := pg_get_functiondef('public.use_blind(uuid,uuid,text)'::regprocedure);
  d2 := replace(d, $x$if me.blind_used then raise exception '시크릿은 한 번만 사용할 수 있어요'; end if;$x$,
                   $x$if me.secrets <= 0 then raise exception '남은 시크릿이 없어요'; end if;$x$);
  d2 := replace(d2, 'update players set blind_used = true where id = me.id;',
                    'update players set secrets = secrets - 1, blind_used = (secrets - 1 <= 0) where id = me.id;');
  if d2 = d or position('secrets - 1' in d2) = 0 then raise exception 'use_blind patch failed'; end if;
  execute d2;

  -- get_state: 남은 시크릿 개수 전달
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$'blind_used', me.blind_used,$x$, $x$'blind_used', me.blind_used, 'secrets', me.secrets,$x$);
  if d2 = d then raise exception 'get_state patch failed'; end if;
  execute d2;
end $$;
