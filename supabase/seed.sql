-- ============================================================================
-- Seed para test de diagnóstico de PowerSync.
--
-- Cómo usar:
--  1. Crea un usuario en Supabase Dashboard → Authentication → Users
--  2. Copia su UUID
--  3. Pégalo abajo donde dice 'PEGA_EL_UUID_DEL_USUARIO_AQUI'
--  4. Corre todo este script en Supabase Dashboard → SQL Editor
--
-- Crea: 1 tenant + 1 cobrador (linkeado al auth user) + 1 plan + 1 cliente
--       + 1 contrato + 1 cuota pendiente.
--
-- Idempotente: si ya existe el cobrador con ese UUID, no rompe — solo añade
-- más datos al mismo tenant.
-- ============================================================================

do $$
declare
  v_user_id   uuid := 'PEGA_EL_UUID_DEL_USUARIO_AQUI';
  v_tenant_id uuid;
  v_plan_id   uuid;
  v_cliente_id uuid;
  v_contrato_id uuid;
begin
  -- Reutilizar tenant existente si el cobrador ya está creado
  select tenant_id into v_tenant_id
  from public.cobradores where id = v_user_id;

  if v_tenant_id is null then
    insert into public.tenants (nombre) values ('ISP de Prueba')
    returning id into v_tenant_id;

    insert into public.cobradores (id, tenant_id, nombre, telefono, rol)
    values (v_user_id, v_tenant_id, 'Cobrador de Prueba', '+50500000000', 'cobrador');
  end if;

  insert into public.planes (tenant_id, nombre, tipo, precio_mensual)
  values (v_tenant_id, 'Internet 10MB', 'internet', 500.00)
  returning id into v_plan_id;

  insert into public.clientes (tenant_id, cobrador_id, nombre, telefono, direccion, zona)
  values (v_tenant_id, v_user_id, 'Cliente de Prueba', '+50511111111',
          'Casa de la esquina', 'Zona A')
  returning id into v_cliente_id;

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_corte, fecha_inicio)
  values (v_tenant_id, v_cliente_id, v_plan_id, 5, current_date)
  returning id into v_contrato_id;

  insert into public.cuotas (tenant_id, contrato_id, cliente_id, periodo,
                             fecha_vencimiento, monto)
  values (v_tenant_id, v_contrato_id, v_cliente_id,
          date_trunc('month', current_date)::date,
          current_date + 5, 500.00);

  raise notice '✅ Seed listo. tenant=% cobrador=%', v_tenant_id, v_user_id;
end $$;
