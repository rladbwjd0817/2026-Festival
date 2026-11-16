-- ============================================================
--  뜰안애 Festival - 추가: 최대 7명 + 관리자 예약현황
--  Supabase > SQL Editor 에 통째로 붙여넣고 [Run] 하세요.
-- ============================================================

-- 1) 관리자 비밀번호 컬럼
alter table public.app_config add column if not exists admin_pw text;

-- ★★ 관리자 비밀번호 설정 (여기 'ddeuran2026' 을 원하는 걸로 바꾸세요) ★★
update public.app_config set admin_pw = 'ddeuran2026' where id = 1;

-- 2) 관람 인원 최대 7명으로 (book_seats 재정의 - 7석까지 허용)
create or replace function public.book_seats(p_seats jsonb, p_name text, p_class text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_group uuid := gen_random_uuid();
  v_item jsonb; v_count int;
  v_conflict text[] := '{}'; v_ids text[] := '{}'; v_id text;
  v_open timestamptz;
begin
  select open_at into v_open from public.app_config where id = 1;
  if v_open is null or now() < v_open then
    return jsonb_build_object('ok', false, 'closed', true, 'message', '아직 예매 오픈 전이에요.');
  end if;

  v_count := coalesce(jsonb_array_length(p_seats), 0);
  if v_count < 1 or v_count > 7 then
    return jsonb_build_object('ok', false, 'message', '1~7석까지만 예약할 수 있어요.');
  end if;
  if coalesce(btrim(p_name), '') = '' or coalesce(btrim(p_class), '') = '' then
    return jsonb_build_object('ok', false, 'message', '아이 이름과 반을 입력해주세요.');
  end if;

  for v_item in select * from jsonb_array_elements(p_seats) loop
    v_id := v_item->>'id';
    begin
      insert into public.bookings(seat_id, section, seat_label, group_id)
      values (v_id, v_item->>'section', v_item->>'label', v_group);
      v_ids := array_append(v_ids, v_id);
    exception when unique_violation then
      v_conflict := array_append(v_conflict, v_id);
    end;
  end loop;

  if array_length(v_conflict, 1) is not null then
    delete from public.bookings where group_id = v_group;
    return jsonb_build_object('ok', false, 'conflict', v_conflict,
      'message', '방금 다른 분이 먼저 예약한 좌석이 있어요: ' || array_to_string(v_conflict, ', '));
  end if;

  insert into public.booking_contacts(group_id, child_name, child_class, seat_ids)
  values (v_group, btrim(p_name), btrim(p_class), v_ids);

  return jsonb_build_object('ok', true, 'group_id', v_group, 'seats', v_ids);
end; $$;
revoke all on function public.book_seats(jsonb, text, text) from public;
grant execute on function public.book_seats(jsonb, text, text) to anon, authenticated;

-- 3) 관리자 예약 전체 조회 (비밀번호 맞아야 결과 반환)
create or replace function public.admin_bookings(p_pw text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ok boolean; v_rows jsonb;
begin
  select (admin_pw is not null and admin_pw = p_pw) into v_ok from public.app_config where id = 1;
  if not coalesce(v_ok, false) then
    return jsonb_build_object('ok', false, 'message', '비밀번호가 틀렸어요.');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'group_id', group_id, 'name', child_name, 'class', child_class,
           'seats', seat_ids, 'at', created_at) order by created_at), '[]'::jsonb)
    into v_rows from public.booking_contacts;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
revoke all on function public.admin_bookings(text) from public;
grant execute on function public.admin_bookings(text) to anon, authenticated;

-- 끝! "Success" 뜨면 정상.
-- 관리자 페이지: https://2026-festival-sage.vercel.app/admin.html  (위에서 정한 비밀번호로 로그인)
