-- ============================================================
--  뜰안애 Festival 좌석 예매 - 데이터베이스 설정
--  Supabase > SQL Editor 에 통째로 붙여넣고 [Run] 하세요.
--  (좌석 중복 예약을 원천 차단하는 핵심 로직입니다)
-- ============================================================

-- 1) 좌석 점유 현황 (공개: 어느 좌석이 예약됐는지만. 개인정보 없음)
create table if not exists public.bookings (
  seat_id    text primary key,          -- 예: "나-37", "라-W1"  (이 PK가 중복 예약을 막아줌)
  section    text not null,
  seat_label text not null,
  group_id   uuid not null,
  created_at timestamptz not null default now()
);
alter table public.bookings enable row level security;

drop policy if exists "anyone can read seat status" on public.bookings;
create policy "anyone can read seat status"
  on public.bookings for select to anon, authenticated using (true);

grant select on public.bookings to anon, authenticated;

-- 2) 예약자 연락 정보 (비공개: 관리자만 Supabase 대시보드에서 조회)
create table if not exists public.booking_contacts (
  group_id    uuid primary key,
  child_name  text not null,
  child_class text not null,
  seat_ids    text[] not null,
  created_at  timestamptz not null default now()
);
alter table public.booking_contacts enable row level security;
-- anon 정책 없음 → 학부모는 남의 이름을 절대 볼 수 없음

-- 3) 실시간: 좌석이 예약되면 모든 사람 화면에서 즉시 회색 처리
alter publication supabase_realtime add table public.bookings;

-- 4) 예약 함수 (전부 성공 or 전부 취소 = 부분 예약 방지, 1~5석 제한)
create or replace function public.book_seats(p_seats jsonb, p_name text, p_class text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group uuid := gen_random_uuid();
  v_item jsonb; v_count int;
  v_conflict text[] := '{}';
  v_ids text[] := '{}';
  v_id text;
begin
  v_count := coalesce(jsonb_array_length(p_seats), 0);
  if v_count < 1 or v_count > 5 then
    return jsonb_build_object('ok', false, 'message', '1~5석까지만 예약할 수 있어요.');
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

  -- 한 좌석이라도 이미 예약됐으면 → 방금 넣은 것 전부 되돌리기
  if array_length(v_conflict, 1) is not null then
    delete from public.bookings where group_id = v_group;
    return jsonb_build_object('ok', false, 'conflict', v_conflict,
      'message', '방금 다른 분이 먼저 예약한 좌석이 있어요: ' || array_to_string(v_conflict, ', '));
  end if;

  insert into public.booking_contacts(group_id, child_name, child_class, seat_ids)
  values (v_group, btrim(p_name), btrim(p_class), v_ids);

  return jsonb_build_object('ok', true, 'group_id', v_group, 'seats', v_ids);
end;
$$;
revoke all on function public.book_seats(jsonb, text, text) from public;
grant execute on function public.book_seats(jsonb, text, text) to anon, authenticated;

-- 5) 예약 취소 함수 (본인 예약번호로 취소)
create or replace function public.cancel_booking(p_group uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  delete from public.bookings where group_id = p_group;
  get diagnostics v_n = row_count;
  delete from public.booking_contacts where group_id = p_group;
  return jsonb_build_object('ok', v_n > 0, 'removed', v_n);
end;
$$;
revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;

-- 끝! "Success. No rows returned" 이 뜨면 정상입니다.
