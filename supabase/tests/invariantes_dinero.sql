-- ============================================================================
-- INVARIANTES DE DINERO — diagnóstico contable de SITECSA CRM
-- ============================================================================
--
-- Propósito: detectar corrupción contable en la data real. Cada invariante
-- es una regla que SIEMPRE debe cumplirse. Si una devuelve > 0 violaciones,
-- hay un bug (o data corrupta de testing) que afecta el dinero del tenant.
--
-- CÓMO USARLO:
--   1. Pegar todo este archivo en Supabase SQL Editor.
--   2. Run. El resultado es UNA tabla con una fila por invariante.
--   3. Columna `violaciones` debe ser 0 en TODAS las filas.
--   4. Si alguna > 0, la columna `ejemplo_ids` muestra los registros
--      ofensivos para investigar.
--
-- ES READ-ONLY: solo SELECT. No modifica nada. Seguro de correr en prod.
--
-- Correr DESPUÉS de cada deploy que toque pagos/cuotas/recibos/contratos.
-- ============================================================================

WITH

-- INV 1: En todo pago NO anulado, lo entregado (monto_original * tasa) debe
-- igualar lo aplicado + el vuelto. Tolerancia 0.50 por redondeo de tasa.
--   monto_original = entregado en moneda original (USD o NIO)
--   monto_cordobas = aplicado a la cuota (entra a la caja del ISP)
--   vuelto_cordobas = devuelto al cliente (siempre en NIO)
inv1 AS (
  SELECT 'INV1: entregado = aplicado + vuelto (pagos)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.pagos
    WHERE anulado = false
      AND ABS((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50
    LIMIT 10
  ) t
),

-- INV 2: cuota.monto_pagado debe igualar la suma de pagos NO anulados
-- aplicados a esa cuota. Es el invariante más crítico — si falla, el
-- recaudado y el saldo de la cuota están mal.
inv2 AS (
  SELECT 'INV2: cuota.monto_pagado = SUM(pagos aplicados)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(cuota_id::text, ', ' ORDER BY cuota_id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id AS cuota_id
    FROM public.cuotas cu
    LEFT JOIN (
      SELECT cuota_id, SUM(monto_cordobas) AS pagado
      FROM public.pagos
      WHERE anulado = false
      GROUP BY cuota_id
    ) p ON p.cuota_id = cu.id
    WHERE cu.estado <> 'anulada'
      AND ABS(cu.monto_pagado - COALESCE(p.pagado, 0)) > 0.01
    LIMIT 10
  ) t
),

-- INV 3: estado de la cuota coherente con lo pagado.
--   pagada   → monto_pagado >= monto + cargos_neto
--   pendiente → monto_pagado = 0
--   parcial  → 0 < monto_pagado < total
inv3 AS (
  SELECT 'INV3: estado de cuota coherente con monto_pagado' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.cuotas
    WHERE estado <> 'anulada'
      AND (
        (estado = 'pagada'    AND monto_pagado < (monto + COALESCE(cargos_neto,0)) - 0.01)
        OR (estado = 'pendiente' AND monto_pagado > 0.01)
        OR (estado = 'parcial'  AND (monto_pagado <= 0.01
              OR monto_pagado >= (monto + COALESCE(cargos_neto,0)) - 0.01))
      )
    LIMIT 10
  ) t
),

-- INV 4: ninguna cuota pagada de más (monto_pagado > total). Si esto pasa,
-- el vuelto no se descontó correctamente y se infló el recaudado.
inv4 AS (
  SELECT 'INV4: ninguna cuota con sobrepago (monto_pagado > total)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.cuotas
    WHERE estado <> 'anulada'
      AND monto_pagado > (monto + COALESCE(cargos_neto,0)) + 0.01
    LIMIT 10
  ) t
),

-- INV 5: todo pago NO anulado debe tener un recibo asociado.
inv5 AS (
  SELECT 'INV5: todo pago no anulado tiene recibo' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(p.id::text, ', ' ORDER BY p.id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND NOT EXISTS (
        SELECT 1 FROM public.recibos r WHERE r.pago_id = p.id
      )
    LIMIT 10
  ) p
),

-- INV 6: vuelto_cordobas nunca negativo (lo refuerza el CHECK, verificamos).
inv6 AS (
  SELECT 'INV6: vuelto_cordobas >= 0' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id FROM public.pagos WHERE vuelto_cordobas < 0 LIMIT 10
  ) t
),

-- INV 7: correlativo de recibo único por (cobrador, prefijo). Dos recibos
-- con el mismo número rompen la numeración fiscal.
inv7 AS (
  SELECT 'INV7: correlativo de recibo único por cobrador+prefijo' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(numero_completo, ', ' ORDER BY numero_completo), '') AS ejemplo_ids
  FROM (
    SELECT numero_completo
    FROM public.recibos
    GROUP BY cobrador_id, prefijo, correlativo, numero_completo
    HAVING COUNT(*) > 1
    LIMIT 10
  ) t
),

-- INV 8: contrato activo siempre tiene cobrador_id (no huérfano operativo).
inv8 AS (
  SELECT 'INV8: contrato activo tiene cobrador asignado' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id FROM public.contratos
    WHERE estado = 'activo' AND cobrador_id IS NULL
    LIMIT 10
  ) t
),

-- INV 9: cuota denormaliza cobrador_id consistente con su contrato.
-- (cuotas manuales con contrato_id NULL se saltan).
inv9 AS (
  SELECT 'INV9: cuota.cobrador_id = contrato.cobrador_id' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(cu.id::text, ', ' ORDER BY cu.id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id
    FROM public.cuotas cu
    JOIN public.contratos ct ON ct.id = cu.contrato_id
    WHERE cu.contrato_id IS NOT NULL
      AND cu.cobrador_id IS DISTINCT FROM ct.cobrador_id
    LIMIT 10
  ) cu
),

-- INV 10: coherencia de tenant entre una fila hija y su padre — lo mismo que
-- enforça el trigger validar_tenant_coherente() (migración 0082). Si una hija
-- quedó con un tenant_id distinto al de su padre, la data está scopeada mal y
-- el dinero podría contarse en el tenant equivocado. Tres sub-checks unidos:
--   pagos.tenant_id        debe == cuotas.tenant_id  (por pago.cuota_id)
--   recibos.tenant_id      debe == pagos.tenant_id   (por recibo.pago_id)
--   cargos_extra.tenant_id debe == cuotas.tenant_id  (por cargo.cuota_id)
-- Hijas SIN padre se excluyen (FK NULL o sin match): igual que el trigger, que
-- solo valida cuando el tenant del padre existe (`v_tenant_padre is not null`).
-- Así un pago manual sin cuota no falsea el conteo.
inv10 AS (
  SELECT 'INV10: tenant_id de hija == tenant_id de su padre (0082)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(ofensor, ', ' ORDER BY ofensor), '') AS ejemplo_ids
  FROM (
    SELECT 'pago:' || p.id::text AS ofensor
    FROM public.pagos p
    JOIN public.cuotas cu ON cu.id = p.cuota_id
    WHERE p.cuota_id IS NOT NULL
      AND p.tenant_id <> cu.tenant_id
    UNION ALL
    SELECT 'recibo:' || r.id::text AS ofensor
    FROM public.recibos r
    JOIN public.pagos p ON p.id = r.pago_id
    WHERE r.pago_id IS NOT NULL
      AND r.tenant_id <> p.tenant_id
    UNION ALL
    SELECT 'cargo:' || ce.id::text AS ofensor
    FROM public.cargos_extra ce
    JOIN public.cuotas cu ON cu.id = ce.cuota_id
    WHERE ce.cuota_id IS NOT NULL
      AND ce.tenant_id <> cu.tenant_id
    LIMIT 10
  ) t
),

-- INV 11: un contrato FIJO (duracion_meses) activo debe tener EXACTAMENTE
-- duracion_meses cuotas generadas. La regla #5 (total = precio×meses) presupone
-- que se generaron `meses` cuotas; si la generación under/over-generó, el total
-- fijo no cuadra con sus cuotas. Indefinidos (duracion_meses NULL/0) se excluyen
-- (#6: no tienen total fijo). Las cuotas MANUALES (cargo de reconexión/instalación,
-- `tipo_cargo_manual` NOT NULL) se auto-asocian un contrato_id pero NO son cuotas de
-- facturación → se EXCLUYEN del conteo (si no, cualquier contrato con un cargo manual
-- daría falso positivo). Las anuladas conservan contrato_id → sí cuentan (no se borran).
inv11 AS (
  SELECT 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas (#5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE COALESCE(ct.estado, 'activo') = 'activo'
      AND ct.duracion_meses IS NOT NULL
      AND ct.duracion_meses > 0
      AND (SELECT COUNT(*) FROM public.cuotas cu
             WHERE cu.contrato_id = ct.id AND cu.tipo_cargo_manual IS NULL)
          <> ct.duracion_meses
    LIMIT 10
  ) t
),

-- INV 12: recaudado por contrato coherente entre las dos formas de calcularlo
-- (regla #4 a nivel agregado). `SUM(cuotas.monto_pagado)` de un contrato debe
-- igualar `SUM(pagos.monto_cordobas)` de los pagos NO anulados de esas cuotas.
-- INV2 lo garantiza por cuota; esto cierra el lazo a nivel contrato y atrapa
-- denormalizaciones rotas (un pago apuntando a una cuota de otro contrato, o
-- monto_pagado desincronizado del agregado). Tolerancia 0.01 por redondeo.
inv12 AS (
  SELECT 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE ABS(
      COALESCE((SELECT SUM(cu.monto_pagado)
                  FROM public.cuotas cu
                 WHERE cu.contrato_id = ct.id), 0)
      - COALESCE((SELECT SUM(pa.monto_cordobas)
                    FROM public.pagos pa
                    JOIN public.cuotas cu2 ON cu2.id = pa.cuota_id
                   WHERE cu2.contrato_id = ct.id
                     AND pa.anulado = false), 0)
    ) > 0.01
    LIMIT 10
  ) t
)

-- INV13 (Sprint 2, 0115): todo AJUSTE es un descuento con motivo. El guard
-- server (trg_cargos_ajuste_guard) lo impide hacia adelante; esto detecta
-- data legacy/migrada inconsistente o un bypass.
,inv13 AS (
  SELECT 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ce.id
    FROM public.cargos_extra ce
    WHERE ce.origen = 'ajuste'
      AND (ce.tipo NOT IN ('descuento_monto', 'descuento_porcentaje')
           OR ce.descripcion IS NULL
           OR btrim(ce.descripcion) = '')
    LIMIT 10
  ) t
)

SELECT * FROM inv1
UNION ALL SELECT * FROM inv2
UNION ALL SELECT * FROM inv3
UNION ALL SELECT * FROM inv4
UNION ALL SELECT * FROM inv5
UNION ALL SELECT * FROM inv6
UNION ALL SELECT * FROM inv7
UNION ALL SELECT * FROM inv8
UNION ALL SELECT * FROM inv9
UNION ALL SELECT * FROM inv10
UNION ALL SELECT * FROM inv11
UNION ALL SELECT * FROM inv12
UNION ALL SELECT * FROM inv13
ORDER BY invariante;
