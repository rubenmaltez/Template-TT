-- 0119 — Feature C: Cambio de fecha de pago por días (offline-first).
--
-- VISIÓN (decisiones de Rubén, 2026-06-14):
--   El cliente quiere mover su día de pago (ej. del 15 al 30, o al 10). Si está
--   AL DÍA, paga los "días puente" entre su fecha vieja y la nueva (prorrateados
--   = precio_mensual / días reales del mes), con RECIBO en el momento. A partir
--   de ahí su calendario corre en el día nuevo. El personal habilitado lo hace
--   desde un botón al lado de "Pagar" (lista de cobros + mapa), en CAMPO, OFFLINE.
--
-- GATING de 2 niveles:
--   (1) Por TENANT: el super_admin activa la feature (setting super-only
--       'cobranza.cambio_fecha_habilitado'). Es excepcional.
--   (2) Por USUARIO: el admin habilita a cobradores/admin_cobranza específicos
--       (columna cobradores.puede_cambiar_fecha). El rol 'admin' siempre puede
--       (con la feature ON). Sin flujo de aprobación extra: el personal habilitado
--       = capacitado.
--
-- MODELO (re-anclaje, orquestado por el CLIENTE como cambios de filas que
--   sincronizan; el server NO necesita una función de re-anclaje):
--   - Cargo PUENTE = una cuota-cargo manual (tipo_cargo_manual='puente') cobrada
--     al instante → genera pago + recibo (línea "Puente de pago"). Entra a
--     RECAUDADO; NO infla el total fijo (precio × meses) — es ingreso extra, como
--     una reconexión (invariantes #9/#10 intactos).
--   - La cuota que caía en la ventana del puente queda ABSORBIDA (anulada, sin
--     pago = sin deuda). La primera cuota completa pasa al día nuevo.
--   - Las cuotas futuras pendientes se mueven al día nuevo: lo hace AUTOMÁTICO el
--     trigger contratos_actualizar_cuotas_futuras_trg (0018) al UPDATE de dia_pago
--     (fecha_vencimiento = calcular_fecha_pago(periodo, dia_pago_nuevo)). El cliente
--     lo espeja local para verlo offline al instante.
--   - Contratos de plazo fijo: el cliente agrega 1 cuota al final (día nuevo) para
--     conservar el conteo (total fijo intacto) → el servicio termina unos días
--     después (los del puente, que pagó). Indefinidos: solo se re-ancla el cushion.
--
-- OFFLINE: como el cobrador opera sin internet, NO se puede usar un RPC server.
--   Los writes ocurren LOCAL (PowerSync) y suben vía RLS. Por eso esta migración
--   EXTIENDE la RLS de contratos/cuotas para permitir esos writes SOLO al personal
--   habilitado y SOLO sobre SUS PROPIOS contratos/cuotas. ⚠ Cambio de acceso
--   sensible — revisar en el audit de seguridad (Fase 4).
--
-- tipo_cargo_manual es TEXTO LIBRE (0051, sin CHECK) → 'puente' no requiere
--   tocar constraints. El label legible se registra en el cliente.
--
-- POST-DEPLOY: bump schema.dart (cobradores.puede_cambiar_fecha) + _schemaVersion
--   27→28 + redeploy sync rules (la columna se agregó a los SELECT de cobradores).

-- =========================================================================
-- 1. Permiso por usuario (lo habilita el admin a cobradores/admin_cobranza)
-- =========================================================================
alter table public.cobradores
  add column if not exists puede_cambiar_fecha boolean not null default false;

-- =========================================================================
-- 2. Setting super-only por tenant: feature habilitada (patrón 0085/0086).
--    Se agrega la clave nueva a seed_settings_super_only y se re-siembra.
-- =========================================================================
create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.cambio_fecha_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite el cambio de fecha de pago por días (personal habilitado por el admin)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;

-- =========================================================================
-- 3. Helper: ¿el usuario actual puede cambiar fecha de pago?
--    feature ON (tenant) AND (rol admin OR permiso por usuario).
-- =========================================================================
create or replace function public.puede_cambiar_fecha_pago()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce((
      select s.valor = 'true'::jsonb
        from public.settings s
       where s.tenant_id = public.current_tenant_id()
         and s.clave = 'cobranza.cambio_fecha_habilitado'
    ), false)
    and coalesce((
      select (c.rol = 'admin' or c.puede_cambiar_fecha)
        from public.cobradores c
       where c.id = auth.uid()
    ), false);
$$;

-- =========================================================================
-- 4. RLS: permitir al personal habilitado los writes del cambio de fecha,
--    SOLO sobre SUS PROPIOS contratos/cuotas (cobrador_id = auth.uid()).
--    Los admins/admin_cobranza ya están cubiertos por *_write_admins (0013).
--    Estas policies SUMAN acceso (permissive OR), gateado por la feature+permiso.
-- =========================================================================

-- contratos: UPDATE (dia_pago / fecha_fin) del re-anclaje.
create policy "contratos_cambiar_fecha" on public.contratos
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- cuotas: INSERT (cargo puente + cuota de cierre en fijos).
create policy "cuotas_cambiar_fecha_insert" on public.cuotas
  for insert
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- cuotas: UPDATE (anular la cuota absorbida; el día de las futuras lo mueve el
-- trigger 0018 como SECURITY DEFINER). NO se habilita DELETE.
create policy "cuotas_cambiar_fecha_update" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- NOTA: pagos/recibos ya permiten al cobrador insertar los suyos (0013), así que
-- el cobro del puente + su recibo no requieren policy nueva.
