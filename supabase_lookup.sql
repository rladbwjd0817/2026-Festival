-- ============================================================
--  뜰안애 Festival - 추가: 예약 조회 (아이 이름 + 반으로 내 좌석 찾기)
--  Supabase > SQL Editor 에 붙여넣고 [Run]
-- ============================================================

-- 아이 이름 + 반으로 예약한 좌석 조회 (어느 기기에서든 확인 가능, 보기 전용)
create or replace function public.find_booking(p_name text, p_class text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_seats text[];
begin
  select seat_ids into v_seats
    from public.booking_contacts
    where child_name = btrim(p_name) and child_class = btrim(p_class)
    limit 1;
  if v_seats is null then
    return jsonb_build_object('ok', false, 'message', '해당 이름·반으로 예약된 내역이 없어요.');
  end if;
  return jsonb_build_object('ok', true, 'seats', v_seats);
end; $$;
revoke all on function public.find_booking(text, text) from public;
grant execute on function public.find_booking(text, text) to anon, authenticated;

-- 끝! "Success" 뜨면 적용 완료.
