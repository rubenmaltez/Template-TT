-- 0113_dias_cuotas_proximas_default_5.sql
--
-- "Días de cuotas próximas" (setting `cobranza.dias_cuotas_visibles`) = rango,
-- en días a partir de hoy, dentro del cual una cuota futura se considera
-- "próxima a pagar" y se muestra al cobrador (mapa + lista "Por cobrar"). Las
-- que vencen más allá del rango quedan FUERA (el cobrador no las ve; en el
-- detalle del contrato salen en gris "no disponible").
--
-- El default histórico del seed era 30; pasa a 5 para TODOS los tenants
-- (existentes y nuevos) — decisión de Rubén ("por defecto siempre 5").
--
-- Sin cambios de schema/columnas → NO requiere bump de _schemaVersion ni
-- redeploy de sync rules (la tabla `settings` ya sincroniza por SELECT *).
-- Idempotente: se puede correr más de una vez sin efectos colaterales.

-- (1) Tenants EXISTENTES → 5 en TODOS. `DO UPDATE` fuerza 5 incluso donde había
--     el viejo default 30 (Rubén: "todos a 5"). Inserta la fila donde falte.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_cuotas_visibles', '5'::jsonb, 'number', 'cobranza',
       'Días de cuotas próximas (rango visible al cobrador)', 'admin'
from public.tenants
on conflict (tenant_id, clave) do update set valor = '5'::jsonb;

-- (2) `dias_gracia` = 10 donde FALTE (defensivo, tenants muy viejos). `DO
--     NOTHING` no pisa la configuración de los que ya la tienen.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_gracia', '10'::jsonb, 'number', 'cobranza',
       'Días entre vencimiento y notificación de mora', 'admin'
from public.tenants
on conflict (tenant_id, clave) do nothing;

-- (3) Tenants NUEVOS: el trigger de alta siembra 30 vía `seed_settings_default`.
--     En vez de recrear esa función entera (riesgo de perder alguna clave),
--     agregamos un paso final al trigger que normaliza el valor a 5. Se mantiene
--     idéntico al cuerpo vigente (0090) + el UPDATE.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  -- Default nuevo: 5 días de cuotas próximas (el seed aún inserta 30; se
  -- normaliza acá para no recrear la función completa).
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  return new;
end;
$$;
