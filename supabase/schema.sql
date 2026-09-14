-- ============================================================
-- MOSS AIR — Supabase 스키마 (사용자 웹 + 개발자 웹 공용)
-- 데이터 흐름: 센서 → ESP32 → Wi-Fi → 서버/API → Supabase → 웹
-- 권한: 일반 사용자(자기 제품만) / 개발자(전체) — RLS + 역할로 분리
-- Supabase 대시보드 > SQL Editor 에 붙여넣어 실행하세요.
-- ============================================================

-- 0) 프로필(역할) : auth.users 확장
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default 'user' check (role in ('user','developer')),
  created_at timestamptz not null default now()
);
-- 개발자 여부 헬퍼(백엔드 권한): JWT의 auth.uid() 기준
create or replace function public.is_developer() returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'developer');
$$;

-- 1) 제품(기기)
create table if not exists public.devices (
  id          uuid primary key default gen_random_uuid(),
  device_code text unique not null,              -- MOSS-001 …
  name        text not null default 'MOSS AIR',
  owner       uuid references auth.users(id) on delete set null,
  firmware    text,
  mode        text not null default 'demo' check (mode in ('demo','real')),
  created_at  timestamptz not null default now(),
  last_comm   timestamptz                        -- 마지막 데이터 수신(연결끊김 판정)
);

-- 2) 센서 측정값 (공통 SensorReading)
create table if not exists public.sensor_readings (
  id           bigint generated always as identity primary key,
  device_id    uuid not null references public.devices(id) on delete cascade,
  ts           timestamptz not null default now(),
  pm25_in real, pm25_out real, temperature real, humidity real,
  water_level real, light real, airflow int, pressure real,
  fan_status text, pump_status text, led_status text
);
create index if not exists idx_readings_device_ts on public.sensor_readings(device_id, ts desc);

-- 3) 필터 상태
create table if not exists public.filter_status (
  id bigint generated always as identity primary key,
  device_id uuid not null references public.devices(id) on delete cascade,
  ts timestamptz not null default now(),
  state text, efficiency real, note text
);

-- 4) 알림
create table if not exists public.alerts (
  id bigint generated always as identity primary key,
  device_id uuid references public.devices(id) on delete cascade,
  ts timestamptz not null default now(),
  level text, title text, cause text, action text, resolved boolean default false
);

-- 5) 기기 이벤트/오류 로그 (센서·팬·펌프·통신·수위·풍량·차압 오류)
create table if not exists public.device_events (
  id bigint generated always as identity primary key,
  device_id uuid references public.devices(id) on delete cascade,
  ts timestamptz not null default now(),
  type text,           -- sensor|fan|pump|comm|water|airflow|pressure
  severity text,       -- info|warn|error
  message text
);

-- 6) 유지관리 기록
create table if not exists public.maintenance_records (
  id bigint generated always as identity primary key,
  device_id uuid references public.devices(id) on delete cascade,
  date date not null default current_date,
  type text, note text
);

-- 7) 성능 시험 (개발자)
create table if not exists public.performance_tests (
  id bigint generated always as identity primary key,
  device_id uuid references public.devices(id) on delete set null,
  name text, test_date date, space text, moss_type text, moss_area text,
  fan text, water text,
  pm25_in real, pm25_out real, airflow text, pressure real, temperature real, humidity real,
  efficiency real, created_by uuid references auth.users(id), created_at timestamptz default now()
);

-- 8) 사용자 문의 (설정 > 개발자에게 문의)
create table if not exists public.support_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  device_id uuid references public.devices(id) on delete set null,
  type text, title text, content text,
  status text not null default '접수' check (status in ('접수','확인 중','처리 중','완료')),
  dev_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- RLS: 사용자=자기 제품만 / 개발자=전체
-- ============================================================
alter table public.profiles           enable row level security;
alter table public.devices            enable row level security;
alter table public.sensor_readings    enable row level security;
alter table public.filter_status      enable row level security;
alter table public.alerts             enable row level security;
alter table public.device_events      enable row level security;
alter table public.maintenance_records enable row level security;
alter table public.performance_tests  enable row level security;
alter table public.support_requests   enable row level security;

-- 본인 프로필만
create policy profiles_self on public.profiles for select using (id = auth.uid() or public.is_developer());

-- 제품: 소유자 또는 개발자
create policy devices_read on public.devices for select using (owner = auth.uid() or public.is_developer());
create policy devices_write on public.devices for all using (public.is_developer()) with check (public.is_developer());

-- 자식 테이블: 해당 제품의 소유자 또는 개발자
create or replace function public.owns_device(dev uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.devices d where d.id = dev and (d.owner = auth.uid() or public.is_developer()));
$$;
create policy readings_read  on public.sensor_readings    for select using (public.owns_device(device_id));
create policy filter_read    on public.filter_status      for select using (public.owns_device(device_id));
create policy alerts_read    on public.alerts             for select using (public.owns_device(device_id));
create policy events_read    on public.device_events      for select using (public.owns_device(device_id));
create policy maint_read     on public.maintenance_records for select using (public.owns_device(device_id));
-- 쓰기(센서/이벤트/필터)는 서버(Edge Function/서비스롤) 또는 개발자만
create policy readings_write on public.sensor_readings    for insert with check (public.is_developer());
create policy events_write   on public.device_events      for all using (public.is_developer()) with check (public.is_developer());
create policy perf_dev       on public.performance_tests  for all using (public.is_developer()) with check (public.is_developer());

-- 문의: 본인 것 생성/조회, 개발자는 전체 조회·상태변경
create policy support_insert on public.support_requests for insert with check (user_id = auth.uid());
create policy support_read   on public.support_requests for select using (user_id = auth.uid() or public.is_developer());
create policy support_update on public.support_requests for update using (public.is_developer()) with check (public.is_developer());

-- 결과: 사용자 A는 사용자 B의 제품·센서·알림·문의를 볼 수 없습니다.
--       개발자 계정만 전체 제품/센서/성능/오류/문의를 관리할 수 있습니다.
