-- Sprint A1 — Rol super_admin + sistema de módulos por tenant
--
-- Cambios:
--   1. Rol 'super_admin' agregado al CHECK constraint de cobradores.
--   2. Tenant 'System' (UUID 0000-...) para alojar a los super_admin.
--   3. Tabla `modulos` (catálogo de módulos del sistema).
--   4. Tabla `tenant_modulos` (qué módulos tiene habilitado cada tenant).
--   5. Trigger: al crear un tenant, auto-habilita los módulos base.
--   6. Funciones helper: is_super_admin(), tenant_tiene_modulo().
--   7. RLS: super_admin tiene acceso cross-tenant a TODAS las tablas.
--   8. handle_new_user actualizado: super_admin → tenant System.

-- =========================================================================
-- 1. Rol super_admin
-- =========================================================================

alter table public.cobradores drop constraint cobradores_rol_check;
alter table public.cobradores add constraint cobradores_rol_check
  check (rol in ('super_admin', 'admin', 'admin_cobranza', 'cobrador'));

-- =========================================================================
-- 2. Tenant 'System' (UUID fijo, conocido)
-- =========================================================================
-- Aloja a los super_admins (el proveedor del SaaS). Invisible para los
-- demás tenants. Sus settings nunca se usan en UI normal.

insert into public.tenants (id, nombre)
  values ('00000000-0000-0000-0000-000000000000', 'System')
  on conflict (id) do nothing;

-- =========================================================================
-- 3. Tabla `modulos` (catálogo del sistema)
-- =========================================================================

create table public.modulos (
  codigo text primary key,            -- 'cobranza', 'inventario', etc.
  nombre text not null,
  descripcion text,
  es_base boolean not null default false,  -- true = se habilita automático en cada tenant nuevo
  orden int not null default 0,
  created_at timestamptz not null default now()
);

-- Seed: módulos iniciales del sistema.
insert into public.modulos (codigo, nombre, descripcion, es_base, orden) values
  ('cobranza',   'Cobranza',
   'Gestión de clientes, contratos, cuotas, cobros e impresión de recibos.',
   true,  10),
  ('inventario', 'Inventario',
   'Gestión de equipos (routers, ONUs, etc.) asignados a clientes.',
   false, 20)
on conflict (codigo) do nothing;

alter table public.modulos enable row level security;

-- Lectura libre: la app necesita saber qué módulos existen para renderizar UI.
create policy "modulos_read" on public.modulos
  for select to authenticated using (true);

-- Sólo super_admin puede agregar/modificar módulos.
create policy "modulos_super_admin_write" on public.modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 4. Tabla `tenant_modulos`
-- =========================================================================

create table public.tenant_modulos (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  modulo_codigo text not null references public.modulos(codigo) on delete restrict,
  habilitado boolean not null default true,
  habilitado_en timestamptz not null default now(),
  habilitado_por uuid references public.cobradores(id) on delete set null,
  primary key (tenant_id, modulo_codigo)
);

alter table public.tenant_modulos enable row level security;

-- El tenant lee sus propios módulos. Super_admin lee/escribe todos.
create policy "tenant_modulos_read" on public.tenant_modulos
  for select using (
    tenant_id = public.current_tenant_id() or public.is_super_admin()
  );

create policy "tenant_modulos_super_admin_write" on public.tenant_modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- Backfill: cada tenant existente recibe los módulos base habilitados.
insert into public.tenant_modulos (tenant_id, modulo_codigo)
  select t.id, m.codigo
  from public.tenants t
  cross join public.modulos m
  where m.es_base = true
on conflict do nothing;

-- =========================================================================
-- 5. Trigger: nuevo tenant → auto-habilita módulos base
-- =========================================================================

create or replace function public.tenants_habilitar_modulos_base_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.tenant_modulos (tenant_id, modulo_codigo)
    select new.id, codigo from public.modulos where es_base = true
  on conflict do nothing;
  return new;
end;
$$;

create trigger trg_tenants_habilitar_modulos_base
  after insert on public.tenants
  for each row execute function public.tenants_habilitar_modulos_base_trg();

-- =========================================================================
-- 6. Funciones helper
-- =========================================================================

create or replace function public.is_super_admin() returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select rol = 'super_admin' from public.cobradores where id = auth.uid()),
    false
  )
$$;

create or replace function public.tenant_tiene_modulo(p_tenant_id uuid, p_modulo text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select habilitado from public.tenant_modulos
      where tenant_id = p_tenant_id and modulo_codigo = p_modulo),
    false
  )
$$;

-- =========================================================================
-- 7. RLS: super_admin tiene acceso cross-tenant en TODAS las tablas
-- =========================================================================
-- Agregamos policies "super_admin_all" en cada tabla operativa.
-- USING = is_super_admin() permite leer/escribir CUALQUIER fila, cross-tenant.

create policy "super_admin_all" on public.tenants
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.cobradores
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.planes
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.clientes
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.contratos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.cuotas
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.pagos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.recibos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.cargos_extra
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.notificaciones_mora
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.settings
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create policy "super_admin_all" on public.audit_log
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- Storage: super_admin tiene acceso a cualquier bucket/path.
create policy "storage_super_admin" on storage.objects
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 8. handle_new_user actualizado para soportar super_admin
-- =========================================================================
-- - Si rol = 'super_admin' → usa tenant System (no crea uno nuevo).
-- - Si sin tenant_id y rol != super_admin → crea tenant nuevo (admin del ISP cliente).
-- - Si con tenant_id → caso invitación (cobrador / admin_cobranza / admin).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  if v_rol not in ('super_admin', 'admin', 'admin_cobranza', 'cobrador') then
    v_rol := 'admin';
  end if;

  if v_rol = 'super_admin' then
    -- Super admin del proveedor SaaS → tenant System.
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  elsif v_tenant_id is null then
    -- Primer admin de un tenant nuevo (creado manualmente desde Supabase
    -- Dashboard sin metadata.tenant_id). Crea el tenant.
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    v_rol := 'admin';
  end if;
  -- Caso restante: hay tenant_id en metadata → invitación. Se usa tal cual.

  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol = 'cobrador' then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;
