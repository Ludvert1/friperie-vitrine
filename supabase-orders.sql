-- =====================================================================
-- Friperie Vitrine — ORDERS + SHOP NOTIFICATIONS  (run once in Supabase > SQL Editor)
-- Safe to run again. Requires supabase-setup.sql to have been run first.
-- =====================================================================

-- ---------- Shop options ----------
alter table public.shops add column if not exists pickup boolean default true;          -- customer can collect at the shop
alter table public.shops add column if not exists delivery_note text default '';        -- e.g. "Cotonou 1 000 F, Calavi 1 500 F"
alter table public.shops add column if not exists fav_count int default 0;

-- protect fav_count like the other counters
create or replace function public.shops_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.settings;
begin
  if public.is_admin() or public.sys_ok() then return new; end if;
  if tg_op = 'INSERT' then
    select * into s from public.settings where id = 1;
    new.owner_id := auth.uid(); new.status := 'pending'; new.plan := 'basic'; new.verified := false;
    new.spotlight_order := 0; new.views := 0; new.wa_clicks := 0; new.web_clicks := 0; new.fav_count := 0;
    new.rating_avg := 0; new.rating_count := 0; new.created_at := now();
    new.paid_until := case when s.trial_days > 0 then now() + make_interval(days => s.trial_days) else null end;
  else
    new.owner_id := old.owner_id; new.status := old.status; new.plan := old.plan; new.verified := old.verified;
    new.paid_until := old.paid_until; new.spotlight_order := old.spotlight_order; new.views := old.views;
    new.wa_clicks := old.wa_clicks; new.web_clicks := old.web_clicks; new.rating_avg := old.rating_avg;
    new.rating_count := old.rating_count; new.created_at := old.created_at; new.slug := old.slug;
    new.fav_count := old.fav_count;
    if old.plan <> 'premium' then new.promo_fr := ''; new.promo_en := ''; end if;
    if jsonb_array_length(coalesce(new.gallery,'[]')) >
       (select case when old.plan='premium' then max_gallery_premium else max_gallery_basic end from public.settings where id=1) then
      raise exception 'gallery_limit';
    end if;
  end if;
  return new;
end $$;

-- ---------- Orders ----------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  shop_id uuid not null references public.shops(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text, image text default '', unit_price int default 0, qty int default 1, total int default 0,
  customer_name text not null, customer_phone text not null,
  delivery_mode text not null default 'pickup' check (delivery_mode in ('pickup','own','shop')),
  address text default '', preferred_date date, note text default '',
  courier_name text default '', courier_phone text default '',
  picked_up_by text default '', picked_up_at timestamptz,
  status text not null default 'new' check (status in ('new','accepted','preparing','ready','picked_up','delivered','cancelled')),
  history jsonb default '[]'::jsonb,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create index if not exists orders_shop_idx on public.orders(shop_id, created_at desc);
alter table public.orders enable row level security;
drop policy if exists "orders owner" on public.orders;
create policy "orders owner" on public.orders for select using (
  public.is_admin() or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
grant select on public.orders to authenticated;

-- ---------- Notifications (one feed per shop) ----------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  kind text not null,              -- order | lead | favorite | review | courier | cancel
  title text, body text, ref text,
  read boolean default false,
  created_at timestamptz default now()
);
create index if not exists notif_shop_idx on public.notifications(shop_id, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists "notif owner read" on public.notifications;
create policy "notif owner read" on public.notifications for select using (
  exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
drop policy if exists "notif owner update" on public.notifications;
create policy "notif owner update" on public.notifications for update using (
  exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid()));
grant select, update on public.notifications to authenticated;

create or replace function public.notify(p_shop uuid, p_kind text, p_title text, p_body text, p_ref text) returns void
language sql security definer set search_path = public as $$
  insert into public.notifications(shop_id, kind, title, body, ref) values (p_shop, p_kind, left(p_title,140), left(p_body,400), p_ref);
$$;
revoke execute on function public.notify(uuid,text,text,text,text) from public, anon, authenticated;

-- live updates for the merchant dashboard
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- new request -> notification
create or replace function public.leads_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.notify(new.shop_id, 'lead', 'Nouvelle demande · ' || coalesce(new.name,''),
    coalesce(nullif(new.product,'') || ' — ', '') || coalesce(new.message,''), new.id::text);
  return new;
end $$;
drop trigger if exists leads_notify on public.leads;
create trigger leads_notify after insert on public.leads for each row execute function public.leads_notify();

-- new review -> notification
create or replace function public.reviews_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.notify(new.shop_id, 'review', 'Nouvel avis ' || repeat('★', new.rating) || ' · ' || coalesce(new.name,''), coalesce(new.comment,''), new.id::text);
  return new;
end $$;
drop trigger if exists reviews_notify on public.reviews;
create trigger reviews_notify after insert on public.reviews for each row execute function public.reviews_notify();

-- ---------- Favorites ----------
create or replace function public.set_favorite(p_shop uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.shop_visible(p_shop) then return; end if;
  perform set_config('vt.sys', '1', true);
  update public.shops set fav_count = greatest(0, coalesce(fav_count,0) + case when p_on then 1 else -1 end) where id = p_shop;
  if p_on then perform public.notify(p_shop, 'favorite', 'Un client a ajouté votre boutique à ses favoris ❤️', '', null); end if;
end $$;

-- ---------- Ordering (customers, no account needed) ----------
create or replace function public.place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr public.products; sh public.shops; q int; c text; m text; tot int;
begin
  select * into pr from public.products where id = (p->>'product_id')::uuid and active;
  if not found then raise exception 'unavailable'; end if;
  select * into sh from public.shops where id = pr.shop_id;
  if not public.shop_visible(sh.id) then raise exception 'shop_unavailable'; end if;
  if coalesce(trim(p->>'name'),'') = '' or length(regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g')) < 8 then raise exception 'missing_contact'; end if;
  m := coalesce(p->>'delivery_mode','pickup');
  if m not in ('pickup','own','shop') then m := 'pickup'; end if;
  if m = 'pickup' and not coalesce(sh.pickup, true) then raise exception 'mode_unavailable'; end if;
  if m = 'shop' and not coalesce(sh.delivery, true) then raise exception 'mode_unavailable'; end if;
  if m = 'shop' and coalesce(trim(p->>'address'),'') = '' then raise exception 'missing_address'; end if;
  q := greatest(1, least(50, coalesce((p->>'qty')::int, 1)));
  tot := coalesce(pr.price,0) * q;
  loop
    c := 'FV-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.orders where code = c);
  end loop;
  insert into public.orders(code, shop_id, product_id, product_name, image, unit_price, qty, total, customer_name, customer_phone,
    delivery_mode, address, preferred_date, note, courier_name, courier_phone, history)
  values (c, sh.id, pr.id, pr.name, coalesce(pr.image,''), coalesce(pr.price,0), q, tot, left(trim(p->>'name'),80), left(trim(p->>'phone'),40),
    m, left(coalesce(p->>'address',''),300), nullif(p->>'preferred_date','')::date, left(coalesce(p->>'note',''),600),
    case when m='own' then left(coalesce(p->>'courier_name',''),80) else '' end,
    case when m='own' then left(coalesce(p->>'courier_phone',''),40) else '' end,
    jsonb_build_array(jsonb_build_object('at', now(), 'status', 'new')));
  perform public.notify(sh.id, 'order', 'Nouvelle commande ' || c || ' · ' || q || ' × ' || pr.name,
    trim(p->>'name') || ' — ' || tot || ' FCFA — ' ||
    case m when 'pickup' then 'Retrait en boutique' when 'own' then 'Livreur du client' else 'Livraison par la boutique' end, c);
  return jsonb_build_object('code', c, 'total', tot);
end $$;

create or replace function public.track_order(p_code text, p_phone text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(o) - 'shop_id' || jsonb_build_object('shop_name', s.name, 'shop_slug', s.slug, 'shop_whatsapp', s.whatsapp, 'shop_address', s.address, 'shop_city', s.city)
  from public.orders o join public.shops s on s.id = o.shop_id
  where upper(o.code) = upper(trim(p_code))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(regexp_replace(p_phone, '\D', '', 'g'), 8)
  limit 1;
$$;

create or replace function public.set_courier(p_code text, p_phone text, p_name text, p_cphone text) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where upper(code) = upper(trim(p_code))
    and right(regexp_replace(customer_phone, '\D', '', 'g'), 8) = right(regexp_replace(p_phone, '\D', '', 'g'), 8);
  if not found or o.status in ('picked_up','delivered','cancelled') then return false; end if;
  update public.orders set delivery_mode = 'own', courier_name = left(p_name,80), courier_phone = left(p_cphone,40), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'status', 'courier', 'by', left(p_name,80)))
  where id = o.id;
  perform public.notify(o.shop_id, 'courier', 'Livreur indiqué pour ' || o.code, left(p_name,80) || ' · ' || left(p_cphone,40), o.code);
  return true;
end $$;

create or replace function public.cancel_order(p_code text, p_phone text) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where upper(code) = upper(trim(p_code))
    and right(regexp_replace(customer_phone, '\D', '', 'g'), 8) = right(regexp_replace(p_phone, '\D', '', 'g'), 8);
  if not found or o.status not in ('new','accepted') then return false; end if;
  update public.orders set status = 'cancelled', updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'status', 'cancelled', 'by', 'client'))
  where id = o.id;
  perform public.notify(o.shop_id, 'cancel', 'Commande annulée par le client · ' || o.code, o.customer_name || ' — ' || o.product_name, o.code);
  return true;
end $$;

-- merchant moves an order forward (only for their own shop)
create or replace function public.shop_update_order(p_id uuid, p_status text, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_id;
  if not found or not (public.is_admin() or exists (select 1 from public.shops s where s.id = o.shop_id and s.owner_id = auth.uid())) then
    raise exception 'forbidden';
  end if;
  if p_status not in ('new','accepted','preparing','ready','picked_up','delivered','cancelled') then raise exception 'bad_status'; end if;
  update public.orders set status = p_status, updated_at = now(),
    picked_up_by = case when p_status = 'picked_up' then left(coalesce(nullif(p_by,''), nullif(courier_name,''), customer_name),80) else picked_up_by end,
    picked_up_at = case when p_status = 'picked_up' then now() else picked_up_at end,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'status', p_status, 'by', left(coalesce(p_by,''),80)))
  where id = p_id;
end $$;

grant execute on function public.set_favorite(uuid, boolean) to anon, authenticated;
grant execute on function public.place_order(jsonb) to anon, authenticated;
grant execute on function public.track_order(text, text) to anon, authenticated;
grant execute on function public.set_courier(text, text, text, text) to anon, authenticated;
grant execute on function public.cancel_order(text, text) to anon, authenticated;
grant execute on function public.shop_update_order(uuid, text, text) to authenticated;

-- refresh the public view so it includes the new shop columns
create or replace view public.public_shops with (security_invoker = true) as
  select * from public.shops
  where status = 'active'
    and paid_until + make_interval(days => (select grace_days from public.settings where id = 1)) > now();
grant select on public.public_shops to anon, authenticated;
