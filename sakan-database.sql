BEGIN;


create extension if not exists btree_gist;
create schema if not exists private;
revoke all on schema private from public;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '', email text, status text not null default 'active' check(status in ('active','suspended')),
 created_at timestamptz not null default now()
);
create table public.roles (id text primary key);
insert into public.roles values ('super_admin'),('operations'),('customer_service'),('accountant'),('staff');
create table public.role_permissions (role_id text references public.roles(id), permission text, primary key(role_id, permission));
insert into public.role_permissions values
 ('operations','catalog.write'),('operations','booking.read'),('operations','operations.write'),('operations','reports.read'),
 ('customer_service','booking.read'),('customer_service','customer.read'),('customer_service','booking.cancel'),
 ('accountant','finance.read'),('accountant','finance.refund'),('accountant','reports.read'),('staff','tasks.assigned');
create table public.user_roles(user_id uuid references public.profiles(id) on delete cascade, role_id text references public.roles(id), primary key(user_id,role_id));
create function public.has_permission(p_permission text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.user_roles r join public.profiles p on p.id=r.user_id
 where r.user_id=auth.uid() and p.status='active' and (r.role_id='super_admin' or exists
 (select 1 from public.role_permissions rp where rp.role_id=r.role_id and rp.permission=p_permission)))
$$;
create function private.new_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.profiles(id) values(new.id); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.new_profile();

create table public.regions(id uuid primary key default gen_random_uuid(), name_ar text not null, name_en text not null, code text unique not null);
create table public.cities(id uuid primary key default gen_random_uuid(), region_id uuid not null references public.regions, name_ar text not null,name_en text not null,is_active boolean not null default false);
create table public.districts(id uuid primary key default gen_random_uuid(),city_id uuid not null references public.cities,name_ar text not null,name_en text not null);
create table public.properties(id uuid primary key default gen_random_uuid(), district_id uuid not null references public.districts,
 code text unique not null,name_ar text not null,name_en text not null, approx_lat numeric not null,approx_lng numeric not null,
 check_in_time time not null default '16:00',check_out_time time not null default '12:00',is_active boolean not null default true);
create table public.property_private(property_id uuid primary key references public.properties on delete cascade,address text not null,latitude numeric,longitude numeric);
create table public.units(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties,
 code text unique not null,name_ar text not null,name_en text not null,description_ar text not null default '',description_en text not null default '',
 kind text not null check(kind in ('studio','apartment')),capacity int not null check(capacity>0),bedrooms int not null default 0 check(bedrooms>=0),
 beds int not null default 1 check(beds>0),bathrooms int not null default 1 check(bathrooms>0),area int check(area>0),
 base_price int not null check(base_price>0),min_nights int not null default 1 check(min_nights>0),
 status text not null default 'draft' check(status in ('draft','published','hidden','maintenance')),
 rules_ar text not null default 'يمنع التدخين والحفلات',rules_en text not null default 'No smoking or parties',created_at timestamptz not null default now());
create table public.unit_images(id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.units on delete cascade,image_url text not null,sort_order int not null default 0,is_cover boolean not null default false);
create unique index unit_cover on public.unit_images(unit_id) where is_cover;
create table public.amenities(id text primary key,name_ar text not null,name_en text not null);
create table public.unit_amenities(unit_id uuid references public.units on delete cascade,amenity_id text references public.amenities,primary key(unit_id,amenity_id));
create table public.unit_rates(unit_id uuid references public.units on delete cascade,day date,price int not null check(price>0),min_nights int not null default 1 check(min_nights>0),primary key(unit_id,day));
create table public.settings(key text primary key,value jsonb not null);
insert into public.settings values('booking','{"hold_minutes":10,"service_fee":0,"tax_basis_points":0,"access_hours_before":2}');
create table public.coupons(id uuid primary key default gen_random_uuid(),code text unique not null check(code=upper(code)),
 percent int not null check(percent between 1 and 100),max_discount int not null check(max_discount>0),minimum int not null default 0 check(minimum>=0),
 starts_at timestamptz not null,ends_at timestamptz not null, max_uses int not null check(max_uses>0),per_customer int not null default 1 check(per_customer>0),
 city_id uuid references public.cities,unit_id uuid references public.units,is_active boolean not null default true,check(ends_at>starts_at));
create sequence public.booking_number_seq start 100001;
create table public.bookings(id uuid primary key default gen_random_uuid(),booking_number text unique not null default ('SKN-'||nextval('public.booking_number_seq')),
 customer_id uuid not null references public.profiles,unit_id uuid not null references public.units,check_in date not null,check_out date not null,
 guests_count int not null check(guests_count>0),nights int generated always as(check_out-check_in) stored,
 status text not null default 'hold' check(status in ('hold','confirmed','checked_in','completed','cancelled','expired')),
 hold_expires_at timestamptz not null,subtotal int not null check(subtotal>=0),service_fee int not null check(service_fee>=0),
 discount int not null check(discount>=0),tax int not null check(tax>=0),total int not null check(total>=0),currency text not null default 'SAR' check(currency='SAR'),
 coupon_id uuid references public.coupons,price_snapshot jsonb not null,request_key uuid not null,
 created_at timestamptz not null default now(),unique(customer_id,request_key),check(check_out>check_in),check(total=subtotal+service_fee-discount+tax));
-- Single inventory ledger for holds, bookings AND administrative blocks.
create table public.inventory_locks(id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.units,
 booking_id uuid unique references public.bookings,stay daterange not null,kind text not null check(kind in ('hold','booking','blocked','maintenance')),
 expires_at timestamptz,reason text,check(not isempty(stay) and lower(stay) is not null and upper(stay) is not null),
 exclude using gist(unit_id with =,stay with &&));
create index booking_customer on public.bookings(customer_id,created_at desc);
create table public.booking_guests(id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.bookings on delete cascade,
 full_name text not null,phone text,email text,is_primary boolean not null default false);
create unique index one_primary_guest on public.booking_guests(booking_id) where is_primary;
create table public.payments(id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.bookings,
 provider text not null,provider_id text unique,amount int not null check(amount>0),currency text not null default 'SAR' check(currency='SAR'),
 status text not null default 'pending' check(status in ('pending','paid','failed','refund_required','refunded','partially_refunded')),
 created_at timestamptz not null default now());
create unique index one_paid_payment on public.payments(booking_id) where status in ('paid','partially_refunded','refunded');
create table public.payment_events(id text primary key,payment_id uuid references public.payments,created_at timestamptz not null default now());
create table public.refunds(id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.bookings,payment_id uuid not null references public.payments,
 amount int not null check(amount>0),reason text not null,status text not null default 'requested' check(status in ('requested','approved','processing','paid','rejected','failed')),
 approved_by uuid references public.profiles,provider_id text unique,created_at timestamptz not null default now());
create table public.reviews(id uuid primary key default gen_random_uuid(),booking_id uuid unique not null references public.bookings,
 customer_id uuid not null references public.profiles,unit_id uuid not null references public.units,rating int not null check(rating between 1 and 5),
 comment text not null default '',published boolean not null default false,created_at timestamptz not null default now());
create table public.favorites(customer_id uuid references public.profiles on delete cascade,unit_id uuid references public.units on delete cascade,primary key(customer_id,unit_id));
create table public.notifications(id uuid primary key default gen_random_uuid(),customer_id uuid not null references public.profiles,
 title text not null,body text not null,booking_id uuid references public.bookings,read_at timestamptz,created_at timestamptz not null default now());
create table public.device_tokens(id uuid primary key default gen_random_uuid(),customer_id uuid not null references public.profiles on delete cascade,token text unique not null,platform text not null);
create table public.notification_outbox(id uuid primary key default gen_random_uuid(),notification_id uuid unique references public.notifications,status text not null default 'pending',attempts int not null default 0,next_attempt_at timestamptz not null default now());
create table public.operations_tasks(id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.units,booking_id uuid references public.bookings,
 kind text not null check(kind in ('cleaning','inspection','maintenance')),status text not null default 'pending' check(status in ('pending','assigned','in_progress','inspection','done')),
 assigned_to uuid references public.profiles,checklist jsonb not null default '{}',notes text not null default '',due_at timestamptz,
 created_at timestamptz not null default now());
create table public.maintenance_requests(id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.units,description text not null,
 priority text not null check(priority in ('low','medium','high','urgent')),blocks_sale boolean not null default false,
 status text not null default 'open' check(status in ('open','in_progress','resolved')),assigned_to uuid references public.profiles,created_at timestamptz not null default now());
create table public.task_attachments(id uuid primary key default gen_random_uuid(),task_id uuid references public.operations_tasks,maintenance_id uuid references public.maintenance_requests,storage_path text not null,check(num_nonnulls(task_id,maintenance_id)=1));
create table public.access_instructions(booking_id uuid primary key references public.bookings,instructions text not null,entry_code text,
 release_at timestamptz not null,expires_at timestamptz not null,check(expires_at>release_at));
create table public.home_content(id uuid primary key default gen_random_uuid(),title_ar text not null,title_en text not null,
 kind text not null check(kind in ('banner','featured','new','popular')),image_url text,unit_ids uuid[] not null default '{}',sort_order int not null default 0,is_active boolean not null default true);
create table public.support_requests(id uuid primary key default gen_random_uuid(),customer_id uuid not null references public.profiles,booking_id uuid references public.bookings,
 kind text not null check(kind in ('support','cancellation','account_deletion')),message text not null,status text not null default 'open',created_at timestamptz not null default now());
create table public.audit_logs(id bigint generated always as identity primary key,actor_id uuid,table_name text not null,record_id text,action text not null,
 before_data jsonb,after_data jsonb,created_at timestamptz not null default now());
create function private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.audit_logs(actor_id,table_name,record_id,action,before_data,after_data)
 values(auth.uid(),tg_table_name,coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id'),tg_op,
 case when tg_op='INSERT' then null else to_jsonb(old)-'entry_code'-'instructions'-'address'-'phone'-'email' end,
 case when tg_op='DELETE' then null else to_jsonb(new)-'entry_code'-'instructions'-'address'-'phone'-'email' end);
 return coalesce(new,old);
end $$;
do $$ declare t text; begin
 foreach t in array array['properties','units','unit_rates','bookings','payments','refunds','coupons','user_roles','role_permissions','settings','access_instructions','operations_tasks','maintenance_requests','inventory_locks'] loop
 execute format('create trigger audit after insert or update or delete on public.%I for each row execute function private.audit_change()',t);
 end loop;
end $$;

-- Default deny every table; all authority comes from explicit policies/functions below.
do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' loop
 execute format('alter table public.%I enable row level security',t.tablename);
 end loop;
end $$;
grant usage on schema public to anon,authenticated;
grant select on all tables in schema public to authenticated;
grant select on public.regions,public.cities,public.districts,public.properties,public.units,public.unit_images,public.amenities,public.unit_amenities,public.reviews,public.home_content to anon;
grant insert,update,delete on public.regions,public.cities,public.districts,public.properties,public.property_private,public.units,public.unit_images,public.amenities,public.unit_amenities,public.unit_rates,public.coupons,public.operations_tasks,public.maintenance_requests,public.access_instructions,public.home_content,public.user_roles,public.role_permissions,public.settings,public.task_attachments to authenticated;
grant insert,delete on public.favorites to authenticated;
grant insert on public.reviews,public.support_requests,public.device_tokens to authenticated;
grant delete on public.device_tokens to authenticated;
grant update(full_name,email) on public.profiles to authenticated;
grant update(read_at) on public.notifications to authenticated;

create policy profile_read on public.profiles for select to authenticated using(id=auth.uid() or public.has_permission('customer.read') or public.has_permission('booking.read'));
create policy profile_edit on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy own_roles on public.user_roles for select to authenticated using(user_id=auth.uid() or public.has_permission('roles.write'));
create policy roles_admin on public.user_roles for all to authenticated using(public.has_permission('roles.write')) with check(public.has_permission('roles.write'));
create policy role_read on public.roles for select to authenticated using(true);
create policy permissions_read on public.role_permissions for select to authenticated using(true);
create policy permissions_admin on public.role_permissions for all to authenticated using(public.has_permission('roles.write')) with check(public.has_permission('roles.write'));
create policy regions_read on public.regions for select using(true);
create policy cities_read on public.cities for select using(is_active or public.has_permission('catalog.write'));
create policy district_read on public.districts for select using(exists(select 1 from public.cities c where c.id=city_id and c.is_active) or public.has_permission('catalog.write'));
create policy property_read on public.properties for select using((is_active and exists(select 1 from public.districts d join public.cities c on c.id=d.city_id where d.id=district_id and c.is_active)) or public.has_permission('catalog.write'));
create policy unit_read on public.units for select using((status='published' and exists(select 1 from public.properties p join public.districts d on d.id=p.district_id join public.cities c on c.id=d.city_id where p.id=property_id and p.is_active and c.is_active)) or public.has_permission('catalog.write'));
create policy images_read on public.unit_images for select using(exists(select 1 from public.units u where u.id=unit_id));
create policy amenities_read on public.amenities for select using(true);
create policy unit_amenities_read on public.unit_amenities for select using(exists(select 1 from public.units u where u.id=unit_id));
create policy home_read on public.home_content for select using(is_active or public.has_permission('content.write'));
do $$ declare t text; begin
 foreach t in array array['regions','cities','districts','properties','property_private','units','unit_images','amenities','unit_amenities','unit_rates'] loop
 execute format('create policy catalog_admin on public.%I for all to authenticated using(public.has_permission(''catalog.write'')) with check(public.has_permission(''catalog.write''))',t);
 end loop;
 foreach t in array array['coupons','home_content'] loop
 execute format('create policy content_admin on public.%I for all to authenticated using(public.has_permission(''content.write'')) with check(public.has_permission(''content.write''))',t);
 end loop;
 foreach t in array array['operations_tasks','maintenance_requests','task_attachments','access_instructions'] loop
 execute format('create policy ops_admin on public.%I for all to authenticated using(public.has_permission(''operations.write'')) with check(public.has_permission(''operations.write''))',t);
 end loop;
end $$;
create policy assigned_tasks on public.operations_tasks for select to authenticated using(assigned_to=auth.uid() and public.has_permission('tasks.assigned'));
create policy bookings_read on public.bookings for select to authenticated using(customer_id=auth.uid() or public.has_permission('booking.read') or public.has_permission('finance.read'));
create policy inventory_admin on public.inventory_locks for select to authenticated using(public.has_permission('catalog.write'));
create policy guests_read on public.booking_guests for select to authenticated using(exists(select 1 from public.bookings b where b.id=booking_id and (b.customer_id=auth.uid() or public.has_permission('booking.read'))));
create policy payments_read on public.payments for select to authenticated using(public.has_permission('finance.read') or exists(select 1 from public.bookings b where b.id=booking_id and b.customer_id=auth.uid()));
create policy refunds_read on public.refunds for select to authenticated using(public.has_permission('finance.read') or exists(select 1 from public.bookings b where b.id=booking_id and b.customer_id=auth.uid()));
create policy favorites_own on public.favorites for all to authenticated using(customer_id=auth.uid()) with check(customer_id=auth.uid());
create policy reviews_read on public.reviews for select using(published or customer_id=auth.uid() or public.has_permission('content.write'));
create policy reviews_insert on public.reviews for insert to authenticated with check(customer_id=auth.uid() and not published and exists(select 1 from public.bookings b where b.id=booking_id and b.customer_id=auth.uid() and b.unit_id=unit_id and b.status='completed'));
create policy notifications_read on public.notifications for select to authenticated using(customer_id=auth.uid() or public.has_permission('content.write'));
create policy notifications_update on public.notifications for update to authenticated using(customer_id=auth.uid()) with check(customer_id=auth.uid());
create policy tokens_own on public.device_tokens for all to authenticated using(customer_id=auth.uid()) with check(customer_id=auth.uid());
create policy support_read on public.support_requests for select to authenticated using(customer_id=auth.uid() or public.has_permission('customer.read'));
create policy support_insert on public.support_requests for insert to authenticated with check(customer_id=auth.uid() and status='open' and (booking_id is null or exists(select 1 from public.bookings b where b.id=booking_id and b.customer_id=auth.uid())));
create policy settings_admin on public.settings for all to authenticated using(public.has_permission('settings.write')) with check(public.has_permission('settings.write'));
create policy audit_admin on public.audit_logs for select to authenticated using(public.has_permission('audit.read'));


create function private.expire_holds(p_unit uuid) returns void language plpgsql set search_path='' as $$
begin
 update public.bookings set status='expired' where unit_id=p_unit and status='hold' and hold_expires_at<=now();
 delete from public.inventory_locks where unit_id=p_unit and kind='hold' and expires_at<=now();
end $$;
create function public.quote_stay(p_unit uuid,p_check_in date,p_check_out date,p_guests int,p_coupon text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.units; c public.coupons; cfg jsonb; subtotal int; fee int; discount int:=0; tax int; lines jsonb; city uuid; minimum_nights int;
begin
 if p_check_in is null or p_check_out is null or p_guests is null or p_check_in<(now() at time zone 'Asia/Riyadh')::date or p_check_out<=p_check_in or p_check_out-p_check_in>60 or p_guests<1 then raise exception 'INVALID_STAY'; end if;
 select * into u from public.units where id=p_unit and status='published';
 select d.city_id into city from public.properties p join public.districts d on d.id=p.district_id join public.cities city_row on city_row.id=d.city_id where p.id=u.property_id and p.is_active and city_row.is_active;
 if u.id is null or city is null then raise exception 'UNIT_UNAVAILABLE'; end if;
 if p_guests>u.capacity then raise exception 'CAPACITY_EXCEEDED'; end if;
 select sum(coalesce(r.price,u.base_price))::int,max(greatest(coalesce(r.min_nights,1),u.min_nights)),
 jsonb_agg(jsonb_build_object('day',s.day::date,'price',coalesce(r.price,u.base_price)) order by s.day)
 into subtotal,minimum_nights,lines from generate_series(p_check_in::timestamp,(p_check_out-1)::timestamp,'1 day') s(day)
 left join public.unit_rates r on r.unit_id=p_unit and r.day=s.day::date;
 if p_check_out-p_check_in<minimum_nights then raise exception 'MINIMUM_NIGHTS'; end if;
 select value into cfg from public.settings where key='booking';
 fee:=coalesce((cfg->>'service_fee')::int,0);
 if nullif(trim(p_coupon),'') is not null then
 select * into c from public.coupons where code=upper(trim(p_coupon)) and is_active and now() between starts_at and ends_at;
 if c.id is null or auth.uid() is null or subtotal<c.minimum or (c.unit_id is not null and c.unit_id<>p_unit) or (c.city_id is not null and c.city_id<>city) then raise exception 'INVALID_COUPON'; end if;
 if (select count(*) from public.bookings where coupon_id=c.id and (status in ('confirmed','checked_in','completed') or (status='hold' and hold_expires_at>now())))>=c.max_uses then raise exception 'COUPON_EXHAUSTED'; end if;
 if (select count(*) from public.bookings where coupon_id=c.id and customer_id=auth.uid() and (status in ('confirmed','checked_in','completed') or (status='hold' and hold_expires_at>now())))>=c.per_customer then raise exception 'COUPON_CUSTOMER_LIMIT'; end if;
 discount:=least(c.max_discount,(subtotal::bigint*c.percent/100)::int);
 end if;
 tax:=round((subtotal+fee-discount)::numeric*coalesce((cfg->>'tax_basis_points')::int,0)/10000)::int;
 return jsonb_build_object('subtotal',subtotal,'service_fee',fee,'discount',discount,'tax',tax,'total',subtotal+fee-discount+tax,'currency','SAR','nights',lines,'coupon_id',c.id,'coupon_code',c.code);
end $$;
create function public.search_units(p_check_in date,p_check_out date,p_guests int default 1)
returns setof public.units language plpgsql security definer set search_path='' as $$
begin
 if p_check_in is null or p_check_out is null or p_guests is null or p_check_in<(now() at time zone 'Asia/Riyadh')::date or p_check_out<=p_check_in or p_check_out-p_check_in>60 or p_guests<1 then raise exception 'INVALID_STAY'; end if;
 return query select u.* from public.units u join public.properties p on p.id=u.property_id join public.districts d on d.id=p.district_id join public.cities c on c.id=d.city_id
 where u.status='published' and p.is_active and c.is_active and u.capacity>=p_guests and u.min_nights<=p_check_out-p_check_in
 and not exists(select 1 from public.unit_rates r where r.unit_id=u.id and r.day>=p_check_in and r.day<p_check_out and r.min_nights>p_check_out-p_check_in)
 and not exists(select 1 from public.inventory_locks l where l.unit_id=u.id and l.stay&&daterange(p_check_in,p_check_out,'[)') and (l.kind<>'hold' or l.expires_at>now())) order by u.base_price;
end $$;
create function public.create_booking_hold(p_unit uuid,p_check_in date,p_check_out date,p_guests int,p_request_key uuid,p_coupon text default null)
returns public.bookings language plpgsql security definer set search_path='' as $$
declare q jsonb; b public.bookings; minutes int;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and status='active') then raise exception 'AUTH_REQUIRED'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 if p_request_key is null then raise exception 'REQUEST_KEY_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_key::text,0));
 select * into b from public.bookings where customer_id=auth.uid() and request_key=p_request_key;
 if b.id is not null then
 if b.unit_id<>p_unit or b.check_in<>p_check_in or b.check_out<>p_check_out or b.guests_count<>p_guests or coalesce(b.price_snapshot->>'coupon_code','')<>upper(trim(coalesce(p_coupon,''))) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
 return b; end if;
 perform 1 from public.units where id=p_unit for update;
 perform private.expire_holds(p_unit);
 if (select count(*) from public.bookings where customer_id=auth.uid() and status='hold' and hold_expires_at>now())>=3 then raise exception 'TOO_MANY_HOLDS'; end if;
 if nullif(trim(p_coupon),'') is not null then perform 1 from public.coupons where code=upper(trim(p_coupon)) for update; end if;
 q:=public.quote_stay(p_unit,p_check_in,p_check_out,p_guests,p_coupon);
 select greatest(1,least(30,(value->>'hold_minutes')::int)) into minutes from public.settings where key='booking';
 insert into public.bookings(customer_id,unit_id,check_in,check_out,guests_count,hold_expires_at,subtotal,service_fee,discount,tax,total,coupon_id,price_snapshot,request_key)
 values(auth.uid(),p_unit,p_check_in,p_check_out,p_guests,now()+make_interval(mins=>coalesce(minutes,10)),(q->>'subtotal')::int,(q->>'service_fee')::int,(q->>'discount')::int,(q->>'tax')::int,(q->>'total')::int,(q->>'coupon_id')::uuid,q,p_request_key) returning * into b;
 insert into public.inventory_locks(unit_id,booking_id,stay,kind,expires_at) values(p_unit,b.id,daterange(p_check_in,p_check_out,'[)'),'hold',b.hold_expires_at);
 return b;
 exception when exclusion_violation then raise exception 'DATES_UNAVAILABLE';
end $$;
create function public.set_booking_guest(p_booking uuid,p_name text,p_phone text,p_email text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 if length(trim(p_name))<2 or p_phone!~'^\+9665[0-9]{8}$' then raise exception 'INVALID_GUEST'; end if;
 perform 1 from public.bookings where id=p_booking and customer_id=auth.uid() and status='hold' and hold_expires_at>now() for update;
 if not found then raise exception 'BOOKING_UNAVAILABLE'; end if;
 insert into public.booking_guests(booking_id,full_name,phone,email,is_primary) values(p_booking,trim(p_name),p_phone,nullif(p_email,''),true)
 on conflict(booking_id) where is_primary do update set full_name=excluded.full_name,phone=excluded.phone,email=excluded.email;
end $$;
-- Called ONLY from a verified server payment adapter. No client execution grant.
create function public.record_verified_payment(p_event text,p_booking uuid,p_provider text,p_provider_id text,p_amount int,p_currency text)
returns text language plpgsql security definer set search_path='' as $$
declare b public.bookings; p public.payments; u uuid;
begin
 select unit_id into u from public.bookings where id=p_booking;
 perform 1 from public.units where id=u for update;
 select * into b from public.bookings where id=p_booking for update;
 if b.id is null or p_amount<>b.total or p_currency<>b.currency then raise exception 'PAYMENT_MISMATCH'; end if;
 if exists(select 1 from public.payment_events where id=p_event) then return 'duplicate'; end if;
 select * into p from public.payments where provider_id=p_provider_id;
 if p.id is not null then
 if p.booking_id<>b.id or p.amount<>p_amount then raise exception 'PAYMENT_MISMATCH'; end if;
 insert into public.payment_events(id,payment_id) values(p_event,p.id); return 'duplicate'; end if;
 insert into public.payments(booking_id,provider,provider_id,amount,currency,status) values(b.id,p_provider,p_provider_id,p_amount,p_currency,'pending') returning * into p;
 insert into public.payment_events(id,payment_id) values(p_event,p.id);
 if b.status<>'hold' or b.hold_expires_at<=now() or not exists(select 1 from public.inventory_locks where booking_id=b.id) then
 update public.payments set status='refund_required' where id=p.id;
 insert into public.refunds(booking_id,payment_id,amount,reason) values(b.id,p.id,p_amount,'Late or duplicate payment: reservation cannot be confirmed');
 perform private.expire_holds(u); return 'refund_required'; end if;
 if not exists(select 1 from public.booking_guests where booking_id=b.id and is_primary) then raise exception 'GUEST_REQUIRED'; end if;
 update public.payments set status='paid' where id=p.id;
 update public.bookings set status='confirmed' where id=b.id;
 update public.inventory_locks set kind='booking',expires_at=null where booking_id=b.id;
 insert into public.notifications(customer_id,title,body,booking_id) values(b.customer_id,'تم تأكيد حجزك',b.booking_number,b.id);
 return 'confirmed';
end $$;
create function public.cancel_booking(p_booking uuid) returns void language plpgsql security definer set search_path='' as $$
declare b public.bookings; u uuid;
begin
 select unit_id into u from public.bookings where id=p_booking;
 perform 1 from public.units where id=u for update;
 select * into b from public.bookings where id=p_booking for update;
 if b.id is null or not (b.customer_id=auth.uid() or public.has_permission('booking.cancel')) then raise exception 'FORBIDDEN'; end if;
 if b.status='cancelled' then return; end if;
 if b.status='hold' then
 update public.bookings set status='cancelled' where id=b.id; delete from public.inventory_locks where booking_id=b.id;
 elsif b.status='confirmed' then
 insert into public.support_requests(customer_id,booking_id,kind,message) values(b.customer_id,b.id,'cancellation','طلب إلغاء يحتاج مراجعة سياسة الإلغاء والاسترداد');
 else raise exception 'CANNOT_CANCEL'; end if;
end $$;
create function public.booking_access(p_booking uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 select jsonb_build_object('instructions',a.instructions,'entry_code',a.entry_code,'address',p.address,'latitude',p.latitude,'longitude',p.longitude)
 into result from public.access_instructions a join public.bookings b on b.id=a.booking_id join public.units u on u.id=b.unit_id join public.property_private p on p.property_id=u.property_id
 where b.id=p_booking and b.customer_id=auth.uid() and b.status in ('confirmed','checked_in') and now()>=a.release_at and now()<a.expires_at
 and exists(select 1 from public.payments x where x.booking_id=b.id and x.status='paid');
 if result is not null then insert into public.audit_logs(actor_id,table_name,record_id,action) values(auth.uid(),'access_instructions',p_booking::text,'READ'); end if;
 return result;
end $$;
create function public.block_unit(p_unit uuid,p_from date,p_to date,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.has_permission('catalog.write') then raise exception 'FORBIDDEN'; end if;
 if p_to<=p_from then raise exception 'INVALID_STAY'; end if;
 perform 1 from public.units where id=p_unit for update;
 perform private.expire_holds(p_unit);
 insert into public.inventory_locks(unit_id,stay,kind,reason) values(p_unit,daterange(p_from,p_to,'[)'),'blocked',p_reason) returning id into result;
 return result;
end $$;
create function public.transition_booking(p_booking uuid,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare b public.bookings;
begin
 if not public.has_permission('operations.write') then raise exception 'FORBIDDEN'; end if;
 select * into b from public.bookings where id=p_booking for update;
 if not ((b.status='confirmed' and p_status='checked_in' and b.check_in<=(now() at time zone 'Asia/Riyadh')::date) or (b.status='checked_in' and p_status='completed')) then raise exception 'INVALID_TRANSITION'; end if;
 update public.bookings set status=p_status where id=b.id;
 if p_status='completed' then
 insert into public.operations_tasks(unit_id,booking_id,kind,due_at) values(b.unit_id,b.id,'cleaning',now());
 insert into public.notifications(customer_id,title,body,booking_id) values(b.customer_id,'كيف كانت إقامتك؟','شاركنا تقييم إقامتك',b.id);
 end if;
end $$;
create function public.update_assigned_task(p_task uuid,p_status text,p_checklist jsonb) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_status not in ('in_progress','inspection') then raise exception 'INVALID_TRANSITION'; end if;
 update public.operations_tasks set status=p_status,checklist=p_checklist where id=p_task and assigned_to=auth.uid() and public.has_permission('tasks.assigned') and status in ('assigned','in_progress');
 if not found then raise exception 'FORBIDDEN'; end if;
end $$;
create function private.maintenance_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.blocks_sale and new.status<>'resolved' then update public.units set status='maintenance' where id=new.unit_id; end if;
 -- Resolution never republishes automatically: supervisor must inspect and republish.
 return new;
end $$;
create trigger maintenance_guard after insert or update on public.maintenance_requests for each row execute function private.maintenance_guard();
create function private.enqueue_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.notification_outbox(notification_id) values(new.id); return new; end $$;
create trigger enqueue_notification after insert on public.notifications for each row execute function private.enqueue_notification();
-- Function execution is opt-in, including every SECURITY DEFINER endpoint.
revoke execute on all functions in schema public from public,anon,authenticated;
revoke execute on all functions in schema private from public,anon,authenticated;
grant execute on function public.has_permission(text),public.search_units(date,date,int),public.quote_stay(uuid,date,date,int,text) to anon,authenticated;
grant execute on function public.create_booking_hold(uuid,date,date,int,uuid,text),public.set_booking_guest(uuid,text,text,text),public.cancel_booking(uuid),public.booking_access(uuid),public.block_unit(uuid,date,date,text),public.transition_booking(uuid,text),public.update_assigned_task(uuid,text,jsonb) to authenticated;
grant execute on function public.record_verified_payment(text,uuid,text,text,int,text) to service_role;
grant all on all tables in schema public to service_role;
grant usage,select on all sequences in schema public to service_role;


drop policy reviews_insert on public.reviews;
create policy reviews_insert on public.reviews for insert to authenticated with check(customer_id=auth.uid() and not published and exists(select 1 from public.bookings b where b.id=reviews.booking_id and b.customer_id=auth.uid() and b.unit_id=reviews.unit_id and b.status='completed'));
create function private.validate_settings() returns trigger language plpgsql set search_path='' as $$
begin
 if new.key='booking' and (coalesce((new.value->>'hold_minutes')::int,0) not between 1 and 30 or coalesce((new.value->>'service_fee')::int,-1)<0 or coalesce((new.value->>'tax_basis_points')::int,-1) not between 0 and 10000) then raise exception 'INVALID_SETTINGS'; end if;
 return new;
end $$;
create trigger validate_settings before insert or update on public.settings for each row execute function private.validate_settings();
create function public.approve_refund(p_payment uuid,p_amount int,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare p public.payments; result uuid; reserved int;
begin
 if not public.has_permission('finance.refund') then raise exception 'FORBIDDEN'; end if;
 select * into p from public.payments where id=p_payment for update;
 if p.id is null or p.status not in ('paid','partially_refunded','refund_required') or p_amount is null or p_amount<=0 or length(trim(p_reason))<2 then raise exception 'INVALID_REFUND'; end if;
 select coalesce(sum(amount),0) into reserved from public.refunds where payment_id=p.id and status in ('approved','processing','paid');
 if reserved+p_amount>p.amount then raise exception 'REFUND_EXCEEDS_PAYMENT'; end if;
 insert into public.refunds(booking_id,payment_id,amount,reason,status,approved_by) values(p.booking_id,p.id,p_amount,p_reason,'approved',auth.uid()) returning id into result;
 return result;
end $$;
create function public.record_verified_refund(p_refund uuid,p_provider_id text,p_amount int) returns void language plpgsql security definer set search_path='' as $$
declare r public.refunds; refunded int;
begin
 select * into r from public.refunds where id=p_refund for update;
 if r.id is null or r.amount<>p_amount then raise exception 'REFUND_MISMATCH'; end if;
 if r.status='paid' and r.provider_id=p_provider_id then return; end if;
 if r.status not in ('approved','processing') then raise exception 'INVALID_REFUND_STATE'; end if;
 perform 1 from public.payments where id=r.payment_id for update;
 update public.refunds set status='paid',provider_id=p_provider_id where id=r.id;
 select sum(amount)::int into refunded from public.refunds where payment_id=r.payment_id and status='paid';
 update public.payments set status=case when refunded=amount then 'refunded' else 'partially_refunded' end where id=r.payment_id;
end $$;
create function public.send_notification(p_customer uuid,p_title text,p_body text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.has_permission('content.write') then raise exception 'FORBIDDEN'; end if;
 if length(trim(p_title))<1 or length(p_title)>150 or length(p_body)>2000 then raise exception 'INVALID_MESSAGE'; end if;
 insert into public.notifications(customer_id,title,body) values(p_customer,p_title,p_body) returning id into result;
 return result;
end $$;
create function public.approve_cancellation(p_booking uuid) returns void language plpgsql security definer set search_path='' as $$
declare b public.bookings; u uuid;
begin
 if not public.has_permission('booking.cancel') then raise exception 'FORBIDDEN'; end if;
 select unit_id into u from public.bookings where id=p_booking;
 perform 1 from public.units where id=u for update;
 select * into b from public.bookings where id=p_booking for update;
 if b.status<>'confirmed' then raise exception 'INVALID_TRANSITION'; end if;
 update public.bookings set status='cancelled' where id=b.id;
 delete from public.inventory_locks where booking_id=b.id;
 update public.support_requests set status='resolved' where booking_id=b.id and kind='cancellation';
 insert into public.notifications(customer_id,title,body,booking_id) values(b.customer_id,'أُلغي حجزك','تُراجع أي مبالغ مستحقة للاسترداد بصورة مستقلة.',b.id);
end $$;
revoke execute on function private.validate_settings() from public,anon,authenticated;
revoke execute on function public.approve_refund(uuid,int,text),public.record_verified_refund(uuid,text,int),public.send_notification(uuid,text,text),public.approve_cancellation(uuid) from public,anon,authenticated;
grant execute on function public.approve_refund(uuid,int,text),public.send_notification(uuid,text,text),public.approve_cancellation(uuid) to authenticated;
grant execute on function public.record_verified_refund(uuid,text,int) to service_role;

-- Supabase Storage only. Test harness provisions the same minimal tables for policy checks.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('unit-images','unit-images',true,10485760,array['image/jpeg','image/png','image/webp']),
 ('operations','operations',false,10485760,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy unit_image_upload on storage.objects for insert to authenticated with check(bucket_id='unit-images' and public.has_permission('catalog.write'));
create policy unit_image_update on storage.objects for update to authenticated using(bucket_id='unit-images' and public.has_permission('catalog.write')) with check(bucket_id='unit-images' and public.has_permission('catalog.write'));
create policy unit_image_delete on storage.objects for delete to authenticated using(bucket_id='unit-images' and public.has_permission('catalog.write'));
create policy operations_files on storage.objects for all to authenticated using(bucket_id='operations' and public.has_permission('operations.write')) with check(bucket_id='operations' and public.has_permission('operations.write'));


create function public.set_cover_image(p_image uuid) returns void language plpgsql security definer set search_path='' as $$
declare u uuid;
begin
 if not public.has_permission('catalog.write') then raise exception 'FORBIDDEN'; end if;
 select unit_id into u from public.unit_images where id=p_image;
 if u is null then raise exception 'IMAGE_NOT_FOUND'; end if;
 perform 1 from public.units where id=u for update;
 update public.unit_images set is_cover=false where unit_id=u and is_cover;
 update public.unit_images set is_cover=true,sort_order=0 where id=p_image;
end $$;
create function public.moderate_review(p_review uuid,p_publish boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.has_permission('content.write') then raise exception 'FORBIDDEN'; end if;
 update public.reviews set published=p_publish where id=p_review;
 if not found then raise exception 'REVIEW_NOT_FOUND'; end if;
end $$;
create function public.resolve_support(p_request uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.has_permission('customer.read') then raise exception 'FORBIDDEN'; end if;
 update public.support_requests set status='resolved' where id=p_request and kind<>'account_deletion';
 if not found then raise exception 'REQUEST_REQUIRES_SPECIAL_HANDLING'; end if;
end $$;
create trigger audit_reviews after update on public.reviews for each row execute function private.audit_change();
create trigger audit_support after update on public.support_requests for each row execute function private.audit_change();
revoke execute on function public.set_cover_image(uuid),public.moderate_review(uuid,boolean),public.resolve_support(uuid) from public,anon,authenticated;
grant execute on function public.set_cover_image(uuid),public.moderate_review(uuid,boolean),public.resolve_support(uuid) to authenticated;



alter table public.properties alter column approx_lat drop not null;
alter table public.properties alter column approx_lng drop not null;
alter table public.properties add constraint properties_location_pair check (
 (approx_lat is null and approx_lng is null) or
 (approx_lat is not null and approx_lng is not null and approx_lat between -90 and 90 and approx_lng between -180 and 180)
) not valid;
create function public.save_property_with_address(p_property jsonb,p_address text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare target_id uuid := coalesce((p_property->>'id')::uuid,gen_random_uuid());
begin
 if not public.has_permission('catalog.write') then raise exception 'Forbidden' using errcode='42501'; end if;
 if p_address is null or length(trim(p_address))=0 or length(p_address)>1000 then raise exception 'Invalid address'; end if;
 insert into public.properties(id,district_id,code,name_ar,name_en,approx_lat,approx_lng,is_active)
 values(target_id,(p_property->>'district_id')::uuid,p_property->>'code',p_property->>'name_ar',p_property->>'name_en',
 (p_property->>'approx_lat')::numeric,(p_property->>'approx_lng')::numeric,coalesce((p_property->>'is_active')::boolean,true))
 on conflict(id) do update set district_id=excluded.district_id,code=excluded.code,name_ar=excluded.name_ar,name_en=excluded.name_en,
 approx_lat=excluded.approx_lat,approx_lng=excluded.approx_lng,is_active=excluded.is_active;
 insert into public.property_private(property_id,address) values(target_id,trim(p_address))
 on conflict(property_id) do update set address=excluded.address;
 return target_id;
end $$;
revoke all on function public.save_property_with_address(jsonb,text) from public,anon;
grant execute on function public.save_property_with_address(jsonb,text) to authenticated;

COMMIT;
