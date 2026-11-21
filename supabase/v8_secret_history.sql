-- v8: 시크릿이 걸렸던 라운드는 게임이 끝날 때까지 라운드별 기록에서 계속 가림 (v7_early_end.sql 이후 적용)
--  이전: 시크릿 기간이 끝나면 그 라운드 기록이 다시 공개됨
--  변경: 진행 중에는 계속 가림, 최종 결과(finished)에서만 공개

do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$h.round + 1 between b.start_round and b.end_round and r.round <= b.end_round), '{}')$x$,
                   $x$h.round + 1 between b.start_round and b.end_round), '{}')$x$);
  if d2 = d then raise exception 'get_state patch failed'; end if;
  execute d2;
end $$;

-- 시크릿 직후 라운드의 '등락'은 가려진 직전 가격을 역산할 수 있으므로 그것도 가림 (가격은 공개)
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.get_state(uuid,uuid)'::regprocedure);
  d2 := replace(d, $x$else '{}'::text[] end as hk$x$,
    $x$else '{}'::text[] end as hk,
              case when r.status = 'playing' then coalesce((select array_agg(b.stock) from blinds b
                where b.room_id = r.id and h.round + 1 between b.start_round and b.end_round + 1), '{}')
              else '{}'::text[] end as hc$x$);
  d2 := replace(d2, $x$'change', ms_mask(q.data->'change', q.hk)$x$, $x$'change', ms_mask(q.data->'change', q.hc)$x$);
  d2 := replace(d2, $x$'change',  case when hid then null else lastrow->'change'->s end,$x$,
    $x$'change',  case when hid or (r.status = 'playing' and exists (select 1 from blinds b where b.room_id = r.id and b.stock = s and b.end_round = r.round - 1))
                       then null else lastrow->'change'->s end,$x$);
  if position('as hc' in d2) = 0 or position('q.hc)' in d2) = 0 or position('b.end_round = r.round - 1' in d2) = 0 then
    raise exception 'get_state change-mask patch failed';
  end if;
  execute d2;
end $$;
