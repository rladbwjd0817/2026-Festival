-- ============================================================
--  뜰안애 Festival - 추가 설정: 예매 오픈 시간 잠금
--  Supabase > SQL Editor 에 통째로 붙여넣고 [Run] 하세요.
-- ============================================================

-- 1) 오픈 시간 설정 테이블 (한 줄만 존재)
create table if not exists public.app_config (
  id      int primary key default 1,
  open_at timestamptz,                 -- 이 시각부터 예매 오픈. null = 잠금(오픈 전)
  constraint app_config_single check (id = 1)
);
insert into public.app_config(id, open_at) values (1, null)
  on conflict (id) do nothing;

alter table public.app_config enable row level security;
drop policy if exists "read config" on public.app_config;
create policy "read config" on public.app_config for select to anon, authenticated using (true);
grant select on public.app_config to anon, authenticated;

-- 2) 예약 함수에 "오픈 시간 체크" 추가 (서버에서 막아 시간 조작 불가)
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
  v_open timestamptz;
begin
  select open_at into v_open from public.app_config where id = 1;
  if v_open is null or now() < v_open then
    return jsonb_build_object('ok', false, 'closed', true, 'message', '아직 예매 오픈 전이에요.');
  end if;

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

-- ============================================================
--  ▼▼▼ 오픈 시간 조절하는 법 (나중에 이 줄만 실행) ▼▼▼
--
--  ● 특정 날짜·시간에 오픈 (예: 11월 20일 금요일 오전 10시):
--    update public.app_config set open_at = '2026-11-20 10:00:00+09' where id = 1;
--
--  ● 지금 당장 오픈:
--    update public.app_config set open_at = now() where id = 1;
--
--  ● 다시 잠그기(오픈 취소):
--    update public.app_config set open_at = null where id = 1;
-- ============================================================
