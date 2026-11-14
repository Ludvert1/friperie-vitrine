-- =====================================================================
--  FRIPERIE VITRINE — Marketplace database (Supabase)
--  Supabase > SQL Editor > New query > paste everything > Run.  Safe to re-run.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- Platform admins ----------
create table if not exists public.admins (email text primary key, user_id uuid);
alter table public.admins add column if not exists user_id uuid;
-- >>> Put YOUR admin email(s) here <<<
insert into public.admins(email) values ('contact@friperies.online'), ('ludvert@gmail.com') on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  -- admin rights are bound to an account id (see 'Activate an admin' below), never to an email typed at sign-up
  select auth.uid() is not null and exists (select 1 from public.admins where user_id = auth.uid());
$$;
-- internal flag used by trusted functions to update protected columns
create or replace function public.sys_ok() returns boolean language sql stable as $$
  select coalesce(current_setting('vt.sys', true), '') = '1';
$$;

-- ---------- Settings ----------
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  momo_number text default '+229 01 94 21 65 68',
  momo_name text default 'Friperie Vitrine',
  support_whatsapp text default '2290194216568',
  support_email text default 'contact@friperies.online',
  price_basic int default 2000,
  price_premium int default 5000,
  trial_days int default 14,
  grace_days int default 3,
  max_products_basic int default 15,
  max_products_premium int default 200,
  max_gallery_basic int default 6,
  max_gallery_premium int default 30
);
insert into public.settings(id) values (1) on conflict do nothing;

-- ---------- Shops ----------
create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  slug text unique not null,
  name text not null,
  category text not null default 'autre',
  city text, address text,
  desc_fr text default '', desc_en text default '',
  phone text, whatsapp text, email text, website text, facebook text, instagram text, hours text,
  delivery boolean default true,
  logo text default '', cover text default '', gallery jsonb default '[]'::jsonb,
  promo_fr text default '', promo_en text default '',
  plan text not null default 'basic' check (plan in ('basic','premium')),
  status text not null default 'pending' check (status in ('pending','active','suspended')),
  paid_until timestamptz,
  verified boolean default false,
  spotlight_order int default 0,
  views int default 0, wa_clicks int default 0, web_clicks int default 0,
  rating_avg numeric default 0, rating_count int default 0,
  created_at timestamptz default now()
);
create unique index if not exists shops_owner_uq on public.shops(owner_id);

-- protect columns that only the platform may change
create or replace function public.shops_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.settings;
begin
  if public.is_admin() or public.sys_ok() then return new; end if;
  if tg_op = 'INSERT' then
    select * into s from public.settings where id = 1;
    new.owner_id := auth.uid(); new.status := 'pending'; new.plan := 'basic'; new.verified := false;
    new.spotlight_order := 0; new.views := 0; new.wa_clicks := 0; new.web_clicks := 0;
    new.rating_avg := 0; new.rating_count := 0; new.created_at := now();
    new.paid_until := case when s.trial_days > 0 then now() + make_interval(days => s.trial_days) else null end;
  else
    new.owner_id := old.owner_id; new.status := old.status; new.plan := old.plan; new.verified := old.verified;
    new.paid_until := old.paid_until; new.spotlight_order := old.spotlight_order; new.views := old.views;
    new.wa_clicks := old.wa_clicks; new.web_clicks := old.web_clicks; new.rating_avg := old.rating_avg;
    new.rating_count := old.rating_count; new.created_at := old.created_at; new.slug := old.slug;
    if old.plan <> 'premium' then new.promo_fr := ''; new.promo_en := ''; end if;
    if jsonb_array_length(coalesce(new.gallery,'[]')) >
       (select case when old.plan='premium' then max_gallery_premium else max_gallery_basic end from public.settings where id=1) then
      raise exception 'gallery_limit';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists shops_guard on public.shops;
create trigger shops_guard before insert or update on public.shops for each row execute function public.shops_guard();

-- public view: only shops that are approved and paid (plus grace period)
create or replace view public.public_shops with (security_invoker = true) as
  select * from public.shops
  where status = 'active'
    and paid_until + make_interval(days => (select grace_days from public.settings where id = 1)) > now();

create or replace function public.shop_visible(p_shop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shops s, public.settings st
    where s.id = p_shop and st.id = 1 and s.status = 'active'
      and s.paid_until + make_interval(days => st.grace_days) > now());
$$;

-- ---------- Products ----------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null, name_en text default '',
  price int not null default 0 check (price >= 0),
  image text default '', description text default '',
  active boolean default true,
  created_at timestamptz default now()
);
create index if not exists products_shop_idx on public.products(shop_id);

create or replace function public.products_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim int; n int;
begin
  if public.is_admin() then return new; end if;
  select case when s.plan = 'premium' then st.max_products_premium else st.max_products_basic end
    into lim from public.shops s, public.settings st where s.id = new.shop_id and st.id = 1;
  select count(*) into n from public.products where shop_id = new.shop_id;
  if n >= lim then raise exception 'product_limit'; end if;
  return new;
end $$;
drop trigger if exists products_limit on public.products;
create trigger products_limit before insert on public.products for each row execute function public.products_limit();

-- ---------- Leads, reviews, payments ----------
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text, phone text, message text, product text,
  created_at timestamptz default now()
);
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null, rating int not null check (rating between 1 and 5), comment text,
  status text default 'visible' check (status in ('visible','hidden')),
  created_at timestamptz default now()
);
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  plan text not null check (plan in ('basic','premium')),
  months int not null check (months in (1,3,6,12)),
  amount int not null,
  momo_txn text not null, momo_sender text,
  status text default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz default now(), approved_at timestamptz
);

create or replace function public.refresh_rating(p_shop uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('vt.sys','1',true);
  update public.shops set
    rating_count = (select count(*) from public.reviews where shop_id = p_shop and status = 'visible'),
    rating_avg = coalesce((select avg(rating) from public.reviews where shop_id = p_shop and status = 'visible'),0)
  where id = p_shop;
  perform set_config('vt.sys','',true);
end $$;
create or replace function public.reviews_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.refresh_rating(coalesce(new.shop_id, old.shop_id)); return null; end $$;
drop trigger if exists reviews_after on public.reviews;
create trigger reviews_after after insert or update or delete on public.reviews for each row execute function public.reviews_after();

-- price is computed on the server, never trusted from the browser
create or replace function public.payments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.settings; base int; off numeric;
begin
  if public.is_admin() then return new; end if;
  select * into s from public.settings where id = 1;
  base := case when new.plan = 'premium' then s.price_premium else s.price_basic end;
  off := case new.months when 3 then 0.05 when 6 then 0.10 when 12 then 2.0/12 else 0 end;
  new.amount := round(base * new.months * (1 - off) / 100.0) * 100;
  new.status := 'pending'; new.approved_at := null; new.created_at := now();
  return new;
end $$;
drop trigger if exists payments_guard on public.payments;
create trigger payments_guard before insert on public.payments for each row execute function public.payments_guard();

-- ---------- Row level security ----------
alter table public.admins   enable row level security;
alter table public.settings enable row level security;
alter table public.shops    enable row level security;
alter table public.products enable row level security;
alter table public.leads    enable row level security;
alter table public.reviews  enable row level security;
alter table public.payments enable row level security;

drop policy if exists "settings read" on public.settings;  create policy "settings read" on public.settings for select using (true);
drop policy if exists "settings admin" on public.settings; create policy "settings admin" on public.settings for update using (public.is_admin());

drop policy if exists "shops read" on public.shops;
create policy "shops read" on public.shops for select using (public.shop_visible(id) or owner_id = auth.uid() or public.is_admin());
drop policy if exists "shops insert" on public.shops;
create policy "shops insert" on public.shops for insert to authenticated with check (true);
drop policy if exists "shops update" on public.shops;
create policy "shops update" on public.shops for update using (owner_id = auth.uid() or public.is_admin());
drop policy if exists "shops delete" on public.shops;
create policy "shops delete" on public.shops for delete using (public.is_admin());

drop policy if exists "products read" on public.products;
create policy "products read" on public.products for select using (
  (active and public.shop_visible(shop_id)) or public.is_admin()
  or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
drop policy if exists "products write" on public.products;
create policy "products write" on public.products for all using (
  public.is_admin() or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()))
  with check (public.is_admin() or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));

drop policy if exists "leads owner" on public.leads;
create policy "leads owner" on public.leads for select using (
  public.is_admin() or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));

drop policy if exists "reviews read" on public.reviews;
create policy "reviews read" on public.reviews for select using (
  status = 'visible' or public.is_admin()
  or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
drop policy if exists "reviews admin" on public.reviews;
create policy "reviews admin" on public.reviews for update using (public.is_admin());

drop policy if exists "payments read" on public.payments;
create policy "payments read" on public.payments for select using (
  public.is_admin() or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
drop policy if exists "payments insert" on public.payments;
create policy "payments insert" on public.payments for insert to authenticated with check (
  exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
drop policy if exists "payments admin" on public.payments;
create policy "payments admin" on public.payments for update using (public.is_admin());

-- ---------- Public functions ----------
create or replace function public.track(p_shop uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.shop_visible(p_shop) then return; end if;
  perform set_config('vt.sys','1',true);
  update public.shops set
    views = views + (case when p_kind = 'view' then 1 else 0 end),
    wa_clicks = wa_clicks + (case when p_kind = 'wa' then 1 else 0 end),
    web_clicks = web_clicks + (case when p_kind = 'web' then 1 else 0 end)
  where id = p_shop;
  perform set_config('vt.sys','',true);
end $$;

create or replace function public.add_lead(p_shop uuid, p_name text, p_phone text, p_message text, p_product text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.shop_visible(p_shop) then raise exception 'shop_unavailable'; end if;
  insert into public.leads(shop_id, name, phone, message, product)
  values (p_shop, left(p_name,80), left(p_phone,40), left(p_message,800), left(p_product,120));
end $$;

create or replace function public.add_review(p_shop uuid, p_name text, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.shop_visible(p_shop) then raise exception 'shop_unavailable'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'bad_rating'; end if;
  insert into public.reviews(shop_id, name, rating, comment) values (p_shop, left(p_name,40), p_rating, left(p_comment,500));
end $$;

create or replace function public.approve_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.payments; s public.shops;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into p from public.payments where id = p_id and status = 'pending' for update;
  if not found then raise exception 'not_pending'; end if;
  select * into s from public.shops where id = p.shop_id for update;
  update public.shops set
    paid_until = greatest(now(), coalesce(s.paid_until, now())) + make_interval(months => p.months),
    plan = p.plan,
    status = case when s.status = 'suspended' then 'suspended' else 'active' end
  where id = s.id;
  update public.payments set status = 'approved', approved_at = now() where id = p.id;
end $$;

grant execute on function public.track(uuid,text) to anon, authenticated;
grant execute on function public.add_lead(uuid,text,text,text,text) to anon, authenticated;
grant execute on function public.add_review(uuid,text,int,text) to anon, authenticated;
grant execute on function public.approve_payment(uuid) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant select on public.public_shops to anon, authenticated;
grant select, insert, update, delete on public.shops, public.products, public.leads, public.reviews, public.payments, public.settings to authenticated;
grant select on public.shops, public.products, public.reviews, public.settings to anon;

-- ---------- Photo storage (each merchant uploads into a folder named after their user id) ----------
insert into storage.buckets (id, name, public) values ('market','market',true)
on conflict (id) do update set public = true;
drop policy if exists "vt upload" on storage.objects;
drop policy if exists "vt delete" on storage.objects;
create policy "vt upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'market' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "vt delete" on storage.objects for delete to authenticated
  using (bucket_id = 'market' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- Activate an admin ----------
-- 1) Create the person's account: Supabase > Authentication > Users > Add user (choose a password, tick Auto Confirm).
-- 2) Then run (replace the email):
--   update public.admins a set user_id = u.id from auth.users u
--   where lower(u.email) = lower(a.email) and lower(a.email) = 'name@example.com';
