-- ============================================================
--  뜰안애 Festival - 최종 마무리 SQL (이 파일 하나만 Run 하면 돼요)
--  ① 같은 아이 중복예약 방지  ② 관리자 비번 보안  ③ 비번 변경  ④ 다시 잠그기
--  Supabase > SQL Editor 에 붙여넣고 [Run]
-- ============================================================

-- ───────── ① 같은 아이(이름+반) 중복 예약 방지 ─────────
create unique index if not exists uq_contact_child
  on public.booking_contacts (child_name, child_class);

create or replace function public.book_seats(p_seats jsonb, p_name text, p_class text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_group uuid := gen_random_uuid();
  v_item jsonb; v_count int;
  v_conflict text[] := '{}'; v_ids text[] := '{}'; v_id text;
  v_open timestamptz;
  v_name text := btrim(p_name);
  v_class text := btrim(p_class);
begin
  select open_at into v_open from public.app_config where id = 1;
  if v_open is null or now() < v_open then
    return jsonb_build_object('ok', false, 'closed', true, 'message', '아직 예매 오픈 전이에요.');
  end if;

  v_count := coalesce(jsonb_array_length(p_seats), 0);
  if v_count < 1 or v_count > 7 then
    return jsonb_build_object('ok', false, 'message', '1~7석까지만 예약할 수 있어요.');
  end if;
  if v_name = '' or v_class = '' then
    return jsonb_build_object('ok', false, 'message', '아이 이름과 반을 입력해주세요.');
  end if;

  if exists(select 1 from public.booking_contacts where child_name = v_name and child_class = v_class) then
    return jsonb_build_object('ok', false, 'dup', true,
      'message', v_name || '(' || v_class || ') 이름으로 이미 예약된 좌석이 있어요. 한 아이는 한 번만 예약할 수 있어요. 자리를 바꾸려면 기존 예약을 먼저 취소해주세요.');
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

  begin
    insert into public.booking_contacts(group_id, child_name, child_class, seat_ids)
    values (v_group, v_name, v_class, v_ids);
  exception when unique_violation then
    delete from public.bookings where group_id = v_group;
    return jsonb_build_object('ok', false, 'dup', true,
      'message', v_name || '(' || v_class || ') 이름으로 방금 예약이 접수됐어요. 중복 예약은 안 돼요.');
  end;

  return jsonb_build_object('ok', true, 'group_id', v_group, 'seats', v_ids);
end; $$;
revoke all on function public.book_seats(jsonb, text, text) from public;
grant execute on function public.book_seats(jsonb, text, text) to anon, authenticated;

-- ───────── ② 관리자 비밀번호가 공개 키로 안 읽히게 (open_at만 공개) ─────────
revoke select on public.app_config from anon, authenticated;
grant select (id, open_at) on public.app_config to anon, authenticated;

-- ───────── ③ 관리자 비밀번호 변경 (★ '바꿀비밀번호' 를 원하는 값으로!) ─────────
update public.app_config set admin_pw = '바꿀비밀번호' where id = 1;

-- ───────── ④ 지금 오픈돼 있으니 다시 잠그기 (학부모 배포 전까지) ─────────
update public.app_config set open_at = null where id = 1;

-- 끝! 나중에 실제로 열 때는 아래 한 줄만:
--   update public.app_config set open_at = now() where id = 1;              (지금 바로)
--   update public.app_config set open_at = '2026-12-01 10:00:00+09' where id = 1;  (예약 오픈)
