-- v11: 매매 수량 상한(한 번에 100,000주) 제거 (v10_trade_frac.sql 이후 적용)
--  현금·보유량 검사는 그대로 유지된다.

do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.trade(uuid,uuid,text,integer)'::regprocedure);
  d2 := replace(d, $x$if p_qty = 0 or abs(p_qty) > 100000 then raise exception '수량이 올바르지 않아요'; end if;$x$,
                   $x$if p_qty is null or p_qty = 0 then raise exception '수량이 올바르지 않아요'; end if;$x$);
  if d2 = d then raise exception 'trade patch failed'; end if;
  execute d2;
end $$;
