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
| **M2** | MEDIUM | RLS de `inv_*`/`tickets` (0099/0103) | Gate de módulos opcionales NO server-enforced (solo router/UI) | ✅ **migración `0114` ESCRITA** (write-only gating + storage; defensiva con `to_regclass`) · ⏳ **correrla** (Rubén, Dashboard) |
| **M3** | MEDIUM | `cobradores_admin_screen.dart` + sync-rules | Rol `admin_tickets` a medio implementar (sin bucket ni shell) | ✅ **mitigado** `2917a73` (no se ofrece) · completar = feature |
| **M4** | MEDIUM | `ticket_sla.dart` + callsites | SLA anclado a `created_at` device-local-naive → corría ~6h post-sync | ✅ **FIXED** `9f60ab9` (`parseTicketWallClock` por componentes, correcto pre y post-sync, 4 callsites) |
| **M5** | MEDIUM | `connector.dart` `_isNonRetryable` | Clasificaba clase 40 (serialization/deadlock) como permanente → descarte silencioso de writes | ✅ **FIXED** `2917a73` |
| **M6** | MEDIUM (op) | migraciones `0099`→`0112` | Posiblemente NO deployadas; con módulo ON el INSERT falla y bloquea la cola de sync | ⏳ **checklist de verificación** abajo (única acción: Rubén) |
| **L1** | LOW | timestamps del cliente | `aplicado_en`/`anulada_en` sin `.toUtc()` | ✅ **ya estaban resueltos** (B10 del audit 2026-06-08) · convención `fecha_pago`/`tickets.created_at` local-naive documentada en CLAUDE.md |
| **L2** | LOW | `aplicar_cargo_dialog.dart` | Cargo no espejaba `cargos_neto`/`estado` local (saldo stale offline) | ✅ **FIXED** `2917a73` (mirror verificado exacto) |
| **L3** | LOW | `audit_admin_screen.dart` | Viewer global ordenaba por `created_at`, no `ocurrido_en` | ✅ **FIXED** `2917a73` |
| **L4** | LOW | `eliminar-cobrador/index.ts` | El conteo pre-delete no cubría tablas nuevas → pérdida silenciosa de atribución / FK violation | ✅ **FIXED** `9f60ab9`+lote 3 (12 conteos nuevos, tolerante a `42P01`/`PGRST205` → desacoplado de M6) · ⏳ **redeploy** edge fn |
| **L5** | LOW | `ticket_detail` historial | `tickets` debía ser Agregador | ✅ **FIXED** `9f60ab9` (`HistorialTicketWidget`: ticket+adjuntos+materiales; eventos excluidos — la bitácora ya los narra) |
| **L6** | LOW | `foto_comprobante_service.dart` | F5 perdía el último `UploadResult` con fallas | ✅ **FIXED** `9f60ab9`+lote 3 (persistido en SharedPreferences; clave se limpia sin pendientes) |
| **L7** | LOW | `_shared/passwords.ts` | Sesgo de módulo en password generada | ✅ **FIXED** `d31bbb8` (rejection sampling) · ⏳ **redeploy** edge fns |
| **L8** | LOW | `router.dart:256` | Gate del técnico no verifica módulo `tickets` ON | ✅ **aceptado by-design** (M3 gatea la asignación del admin; 0114 bloquea writes server-side; el super asigna deliberadamente) |

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
- **Commit `9f60ab9`** (lote 2): M4 (`parseTicketWallClock` — SLA correcto pre/post-sync),
  M2 (migración `0114` escrita), L4 (conteos extendidos en `eliminar-cobrador`),
  L5 (`HistorialTicketWidget` agregador), L6 (UploadResult persistido), L1 (verificado
  ya-resuelto + convención documentada en CLAUDE.md).
- **Lote 3** (fixes convergentes del AUDIT FINAL — 3 agentes sobre todo el diff):
  `PGRST205` además de `42P01` en la tolerancia de `eliminar-cobrador` (PostgREST
  moderno NO devuelve 42P01 para tabla inexistente — sin esto la tolerancia no
  toleraba nada) · +4 conteos (FK NO ACTION: `contratos`/`cuotas`/`fotos_cliente`
  `.cobrador_id` + `ticket_adjuntos.subido_por`) · la 0114 gatea también la policy
  de **storage** `ticket-adjuntos` (gap del audit de deployment) · clave stale de
  fotos se limpia sin pendientes · verbos `tickets`/`ticket_adjuntos` en `_labelFor`
  (timeline mezclada legible) · 3 comments corregidos (alfabeto 63 chars,
  `tenant_dialogs_miembro`, no-op silencioso de UPDATE/DELETE en 0114).

**Veredicto del AUDIT FINAL (3 agentes: correctness + deployment safety + QA de
conformidad):** los 14 findings resueltos o justificados, **sin gaps de código**.
La 0114 verificada policy-por-policy contra las originales (equivalencia exacta +
gate), sintaxis PL/pgSQL válida, SELECT preservado vía policies `_read`, trigger
SECURITY DEFINER intacto, idempotente. Sin TODO/FIXME nuevos, sin SQL
Postgres-only, sin `date('now')` pelados, símbolos nuevos todos usados.

---

## ⏳ Pendientes (única persona: Rubén — deploy/verificación)

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

### Correr migración `0114` (M2 — ya escrita y auditada)
`supabase/migrations/0114_gate_modulos_server_side.sql` por el SQL Editor. Gatea la
**escritura** de inv_*/tickets/incidentes + el storage de `ticket-adjuntos` con
`tenant_tiene_modulo()` (lectura NO se gatea — no esconder data histórica;
`super_admin_all` intacta). Es **defensiva**: si 0099→0107 no corrieron aún, se
saltea con NOTICEs — en ese caso **RE-CORRERLA al final**, después del bloque.
**Orden recomendado: 0114 SIEMPRE ÚLTIMA** + correr la query de verificación del
final del archivo (10 policies, cada qual/with_check con `tenant_tiene_modulo`).

### Redeploy de edge functions (L4 + L7 — código listo y auditado)
- `eliminar-cobrador` (conteos extendidos, tolerante a tablas faltantes — seguro
  de deployar ANTES o después de M6).
- Cualquier función que importe `_shared/passwords.ts` (el `_shared/` se deploya
  vía CLI/repo según el flujo documentado en CLAUDE.md).

### Rebuild + testing manual
Mucho código Dart nuevo → `git pull` + `flutter run` desde cero. Smoke tests
sugeridos: (1) forzar-password a un cobrador → el afectado re-loguea SIN F5;
(2) aplicar un cargo offline → el saldo cambia al instante; (3) crear un ticket
→ sincronizar → el deadline del SLA NO se corre; (4) historial del ticket
muestra ticket+adjuntos+materiales; (5) con módulo OFF (post-0114), un write
directo de inventario/tickets se rechaza.
