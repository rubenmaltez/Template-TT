# AUDIT INTEGRAL — Cobranza ISP (2026-06-09)

> Auditoría profunda de **toda la app**: lógica de cada módulo, interacciones
> entre entidades, y conformidad con el lifecycle y la misión del producto.
> Método: **6 agentes en paralelo** (read-only) por dominio + verificación
> directa de los findings accionables. Sucesora del `AUDIT-INTEGRAL-2026-06-08.md`.

## Metodología

| Dominio | Foco |
|---|---|
| 1. Dinero / cobranza | pagos·cuotas·recibos·contratos·cargos·arqueo vs los 10 invariantes |
| 2. Cobrador / offline-first | flow de cobro, foto, impresora, mapa, historial, sync lifecycle |
| 3. Audit log / change log | modelo completo (profundidad, agregadores, triggers, cobertura) |
| 4. Inventario·Tickets·Técnicos·Incidentes | interacciones consumo→serial→movimiento→cliente, SLA, incidente→afectados |
| 5. Multi-tenant / RLS / seguridad | aislamiento, impersonación, edge functions, auth |
| 6. Integridad estructural | DB↔schema↔sync-rules↔db.dart + SQLite/Postgres + rutas GoRouter |

Cobertura: **177 archivos Dart, 113 migraciones, 6 Edge Functions**, sync-rules y schema.

## Veredicto general

**App sólida y conforme a su misión.** Núcleo de dinero **10/10 invariantes** OK,
cadena de integridad estructural **limpia**, change log con **cobertura 100%**
(27/27 tablas), aislamiento multi-tenant **sin fugas cross-tenant**. **Sin findings
CRITICAL/HIGH.** El riesgo real es **operativo (deploy de 0099-0113)** + un puñado
de MEDIUM concretos.

---

## Findings

| # | Sev | Ubicación | Problema | Estado |
|---|-----|-----------|----------|--------|
| **M1** | MEDIUM | `lib/powersync/db.dart` `connectPowerSync()` | No tomaba el lock `_pendingOp` → race signOut→signIn (causa del "sync gate stuck post-forzar-password") | ✅ **FIXED** `2917a73` |
| **M2** | MEDIUM | RLS de `inv_*`/`tickets` (0099/0103) | Gate de módulos opcionales NO server-enforced (solo router/UI) | ⏳ propuesta (migración) |
| **M3** | MEDIUM | `cobradores_admin_screen.dart` + sync-rules | Rol `admin_tickets` a medio implementar (sin bucket ni shell) | ✅ **mitigado** `2917a73` (no se ofrece) · completar = feature |
| **M4** | MEDIUM | `ticket_sla.dart` + `ticket_form_screen.dart` | SLA anclado a `created_at` device-local-naive → puede correr ~6h post-sync | ⏳ requiere verificación empírica |
| **M5** | MEDIUM | `connector.dart` `_isNonRetryable` | Clasificaba clase 40 (serialization/deadlock) como permanente → descarte silencioso de writes | ✅ **FIXED** `2917a73` |
| **M6** | MEDIUM (op) | migraciones `0099`→`0112` | Posiblemente NO deployadas; con módulo ON el INSERT falla y bloquea la cola de sync | ⏳ **checklist de verificación** abajo |
| **L1** | LOW | `pagos_repo.dart:78`, tickets `created_at`, `aplicado_en`/`anulada_en` | Timestamps del cliente en hora local-naive, no `.toUtc()` | ⏳ batch con M4 |
| **L2** | LOW | `aplicar_cargo_dialog.dart` | Cargo no espejaba `cargos_neto`/`estado` local (saldo stale offline) | ✅ **FIXED** `2917a73` (mirror verificado exacto) |
| **L3** | LOW | `audit_admin_screen.dart` | Viewer global ordenaba por `created_at`, no `ocurrido_en` | ✅ **FIXED** `2917a73` |
| **L4** | LOW | `eliminar-cobrador/index.ts` | El conteo pre-delete no cubre tablas nuevas (visitas/fotos/tickets/inv) → pérdida silenciosa de atribución | ⏳ **acoplado a M6** (hacer tras confirmar deploy) |
| **L5** | LOW | `ticket_detail` historial | `ticket_eventos`/`ticket_adjuntos` solo en viewer global; `tickets` debería ser Agregador | ⏳ backlog (acoplado a M6) |
| **L6** | LOW | `foto_comprobante_service.dart` | F5 pierde el último `UploadResult` con fallas | backlog conocido |
| **L7** | LOW | `_shared/passwords.ts` | Sesgo de módulo (`bytes % 61`) | ✅ **FIXED** `d31bbb8` (rejection sampling) · requiere redeploy edge fns |
| **L8** | LOW | `router.dart:256` | Gate del técnico no verifica módulo `tickets` ON | backlog |

---

## ✅ Lo que está LIMPIO (verificado)

- **Dinero (10/10):** vuelto siempre NIO, `monto_cordobas`=aplicado, multi-cuota/USD,
  anular preserva+restaura, cancelar contrato liquida sin borrar plata y es terminal,
  total fijo=precio×meses, **consistencia cross-pantalla #10** (fórmula idéntica en
  todas las pantallas), arqueo USD cuadra aunque cambie la tasa.
- **Integridad estructural:** schema v26 coherente, migraciones 0001-0113 sin gaps,
  0 SQL Postgres-only, TZ `-6h` al 100% en cortes de día, rutas GoRouter completas,
  streams lifecycle OK, denormalización completa en INSERTs offline.
- **Change log:** 27/27 tablas con trigger (`depth<2`) + registro Dart + acceso UI;
  regla de profundidad/superficie/recibo-excepción bien implementada; append-only y
  server-gana respetados.
- **Multi-tenant:** sin fugas cross-tenant; RLS en 36 tablas; `current_tenant_id()`/
  `is_super_admin()` no spoofeables; freeze de rol; impersonación defendida (cliente +
  `validar_tenant_coherente` server); 6 edge functions robustas; onboarding sin email seguro.
- **Offline-first cobrador:** cobro local transaccional, mirror fiel al trigger,
  impresora 100% offline, mapa con caché de tiles, correlativo de recibo consulta server
  MAX, gate de visibilidad no esconde deuda.
- **Inventario/Tickets:** flujo end-to-end offline-first; cadena consumo→serial→
  `inv_movimientos`→equipo del cliente correcta; stock como ledger sin doble-conteo;
  transición de estado server-side; incidente→afectados derivados de la red.

**Conformidad con la misión/visión: alta.** Cada módulo acerca al MVP de "reemplazar
Excel + WhatsApp". El mayor riesgo del bloque nuevo es de **deploy**, no de diseño.

---

## Fixes aplicados (esta sesión)

- **Commit `2917a73`** (lote 1, auditado por 2 agentes — correctness limpio + dinero exacto):
  M1 (lock de sync), M5 (retryable clase 40), M3 (no ofrecer `admin_tickets`),
  L2 (mirror local de `cargos_neto`/`estado`), L3 (orden/display por `ocurrido_en`).
- **Commit `d31bbb8`**: L7 (password rejection sampling). **Requiere redeploy** de las
  edge functions que importan `_shared/passwords.ts`.

---

## ⏳ Pendientes (necesitan decisión / deploy / verificación)

### M6 — Verificar deploy de 0099→0113 (PRIORIDAD)
Correr en el SQL Editor de Supabase para confirmar que el bloque está aplicado:

```sql
-- (a) ¿Existen las 15 tablas del bloque nuevo? Esperado: 15 filas.
SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN (
  'red_nodos','red_hubs','red_puertos',
  'inv_categorias','inv_proveedores','inv_productos','inv_ubicaciones',
  'inv_seriales','inv_movimientos','ticket_tipos','tickets','ticket_eventos',
  'ticket_adjuntos','ticket_materiales','incidentes') ORDER BY tablename;

-- (b) ¿Las columnas tardías existen? Esperado: 6 filas.
SELECT table_name, column_name FROM information_schema.columns
 WHERE table_schema='public' AND (
   (table_name='inv_productos' AND column_name='stock_minimo') OR
   (table_name='ticket_tipos'  AND column_name='checklist_template') OR
   (table_name='tickets'       AND column_name IN ('segundos_pausado','en_espera_desde','incidente_id')) OR
   (table_name='incidentes'    AND column_name='alcance_label'));

-- (c) ¿Los triggers de negocio están? Esperado: filas para cada tabla.
SELECT tgrelid::regclass AS tabla, tgname FROM pg_trigger
 WHERE NOT tgisinternal AND tgrelid::regclass::text IN
   ('public.tickets','public.ticket_materiales','public.inv_movimientos',
    'public.inv_seriales','public.incidentes') ORDER BY 1,2;
```
Si falta algo → correr las migraciones faltantes (0099→0112 en orden) + **redeploy de
sync rules** ANTES de habilitar los módulos `inventario`/`tickets` a cualquier tenant.
Mientras no estén deployadas, **no habilitar esos módulos** (el INSERT fallaría y
bloquearía la cola de sync del cliente).

### M2 — Gate de módulos server-enforced (decisión + migración)
Hoy un admin de un tenant con el módulo OFF puede leer/escribir `inv_*`/`tickets` vía
REST/PowerSync directo (mismo tenant, **no cruza tenants** — es consistencia comercial).
Fix propuesto: migración 0114 que recrea las policies de **escritura** (insert/update/
delete) de inv_*/tickets/incidentes agregando
`AND public.tenant_tiene_modulo(current_tenant_id(), 'inventario'|'tickets')`.
`super_admin_all` queda intacta (el super siempre tiene acceso).
**Decisión abierta:** ¿gatear también la **lectura** (SELECT)? Si sí, al apagar un
módulo su data desaparece de la UI (más limpio, pero oculta data existente). Toca ~9
tablas de policies → requiere deploy y testing.

### M4 + L1 — Timestamps del cliente en hora local-naive
El SLA del ticket se ancla a `created_at` escrito como hora local-naive (sin offset).
Pre-sync funciona; **post-sync el deadline podría correr ~6h** (round-trip a `timestamptz`).
**Verificar empíricamente** (crear ticket → sincronizar → comparar el deadline antes/
después del primer checkpoint). Si corre 6h, anclar el SLA a un `created_at` normalizado
con `.toUtc()`. Mismo patrón sistémico en `fecha_pago` y `aplicado_en`/`anulada_en` (L1)
— normalizar los timestamps del cliente a `.toUtc()` en un batch.

### L4 — `eliminar-cobrador` (tras confirmar M6)
Extender el conteo pre-delete a visitas/fotos_cliente/tickets/ticket_eventos/
inv_movimientos/inv_ubicaciones. **Implementar DESPUÉS de confirmar el deploy** (si esas
tablas no existen, la query de conteo falla y la función devolvería 500 bloqueando toda
eliminación). Requiere redeploy de la edge function.

### L5/L6/L8 — backlog
- L5: convertir el historial del ticket en Agregador (surface `ticket_eventos`/
  `ticket_adjuntos`) — LOW, acoplado a M6.
- L6: persistir el último `UploadResult` de fotos (F5) — backlog conocido.
- L8: gate de módulo del técnico en el router — LOW.
