-- v10: 비율 매수 (v9_kick.sql 이후 적용)
--  시크릿으로 가격이 가려진 종목은 화면이 살 수 있는 수량을 모르므로,
--  서버가 실제 가격으로 "남은 현금 × 비율"만큼 살 수 있는 최대 수량을 계산해 매수한다.
--  반환값: 실제로 산 주식 수

create or replace function public.trade_frac(p_player uuid, p_secret uuid, p_stock text, p_frac numeric) returns int language plpgsql security definer set search_path = public as $$
declare me players; r rooms; price bigint; q int;
begin
  me := ms_auth(p_player, p_secret);
  if not (p_stock = any(ms_stocks())) then raise exception '없는 종목이에요'; end if;
  if p_frac is null or p_frac <= 0 or p_frac > 1 then raise exception '비율이 올바르지 않아요'; end if;
  select * into r from rooms where id = me.room_id for update;
  if r.status <> 'playing' then raise exception '거래 시간이 아니에요'; end if;
  select * into me from players where id = me.id for update;
  price := (r.prices->>p_stock)::bigint;
  q := floor(me.cash * p_frac / price);
  if q <= 0 then raise exception '현금이 부족해서 1주도 살 수 없어요'; end if;
  perform trade(p_player, p_secret, p_stock, q);
  return q;
end $$;
revoke execute on function public.trade_frac(uuid, uuid, text, numeric) from public;
grant execute on function public.trade_frac(uuid, uuid, text, numeric) to anon, authenticated;
