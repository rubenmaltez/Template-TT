-- 0090 — Sembrar `recibo.layout` en tenants nuevos (faltaba en el seed de alta).
--
-- Bug: el layout configurable del recibo (0080) se sembró SOLO como backfill de
-- los tenants que existían en ese momento. La función de alta de tenant
-- (seed_settings_default, 0010/0045) NUNCA incluyó `recibo.layout`, así que un
-- tenant creado DESPUÉS de 0080 no tiene la fila. El editor de recibos guardaba
-- con un UPDATE puro → 0 filas afectadas → los toggles de visibilidad "rebotaban"
-- (no se podían desactivar).
--
-- Fix de dos capas:
--   - Cliente (v0.6.4): el editor pasa a `upsert` (crea la fila si falta).
--   - Servidor (esta migración): el trigger de alta siembra `recibo.layout`, y
--     se backfillea cualquier tenant que hoy no la tenga.
--
-- Default = mismo layout que 0080 (12 bloques, todo visible, tamaño normal). El
-- cliente agrega el bloque `mora` al final si falta (ReciboLayout.fromRaw), igual
-- que con los tenants existentes. Fila key-value, sin columnas → sin bump de
-- schema ni redeploy de sync rules (settings ya sincroniza con SELECT *).

create or replace function public.seed_settings_recibo_layout(p_tenant_id uuid)
returns void
language plpgsql as $$
declare
  v_layout text := '[' ||
    '{"id":"logo","visible":true,"size":"normal"},' ||
    '{"id":"empresa","visible":true,"size":"normal"},' ||
    '{"id":"titulo","visible":true,"size":"normal"},' ||
    '{"id":"meta","visible":true,"size":"normal"},' ||
    '{"id":"cliente","visible":true,"size":"normal"},' ||
    '{"id":"servicio","visible":true,"size":"normal"},' ||
    '{"id":"cuota","visible":true,"size":"normal"},' ||
    '{"id":"metodo","visible":true,"size":"normal"},' ||
    '{"id":"letras","visible":true,"size":"normal"},' ||
    '{"id":"totales","visible":true,"size":"normal"},' ||
    '{"id":"pie","visible":true,"size":"normal"},' ||
    '{"id":"whatsapp","visible":true,"size":"normal"}' ||
  ']';
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'recibo.layout', v_layout::jsonb, 'json', 'recibos',
     'Layout del recibo: orden, visibilidad y tamaño de cada bloque', 'admin')
  on conflict (tenant_id, clave) do nothing;
end $$;

-- Extender el trigger de alta para que TODO tenant nuevo reciba el layout.
-- Preserva las dos siembras existentes (default 0010/0045 + super_only 0085/0086).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  return new;
end;
$$;

-- Backfill: cualquier tenant que hoy no tenga `recibo.layout` (creado entre 0080
-- y esta migración). ON CONFLICT DO NOTHING preserva el layout ya configurado.
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_recibo_layout(v_t.id);
  end loop;
end $$;
