-- Общий счётчик посещений DerekSci.
-- Публичный клиент не получает прямого доступа к таблице: чтение и инкремент
-- выполняются только через security definer RPC.

create table if not exists public.site_visit_counter (
  singleton boolean primary key default true check (singleton),
  visit_count bigint not null default 0 check (visit_count >= 0),
  updated_at timestamptz not null default now()
);

alter table public.site_visit_counter enable row level security;
revoke all on table public.site_visit_counter from anon, authenticated;

create or replace function public.record_site_visit(p_increment boolean default true)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  total bigint;
begin
  if p_increment then
    insert into public.site_visit_counter (singleton, visit_count, updated_at)
    values (true, 1, now())
    on conflict (singleton) do update
      set visit_count = public.site_visit_counter.visit_count + 1,
          updated_at = now()
    returning visit_count into total;
  else
    select visit_count into total
    from public.site_visit_counter
    where singleton = true;
  end if;

  return coalesce(total, 0);
end;
$$;

revoke all on function public.record_site_visit(boolean) from public;
grant execute on function public.record_site_visit(boolean) to anon, authenticated;

