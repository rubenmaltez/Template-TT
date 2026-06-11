# Guía de testing del sistema

Pasos para validar que el sistema funciona end-to-end.
- La **sección 0** es el loop de TODOS los días (lo que hace Rubén para probar un
  cambio nuevo en Windows). Es lo que más se pierde entre sesiones → mantenerla viva.
- Las **secciones 1-5** son el setup/smoke completo (correr una vez tras desplegar
  Supabase o ante un cambio grande).

---

## 0. Loop de testing manual (uso diario en Windows)

> **Claude: cuando entregues un cambio, dale a Rubén los pasos en ESTE formato**
> (qué hacer → qué debería ver → qué hacer si falla). Si el cambio toca un feature,
> agregá/actualizá su checklist en §0.3.

### 0.1 Traer el cambio y correr

```powershell
# 1) Parado en la branch de trabajo (ver BITACORA.md § ESTADO ACTUAL cuál es)
git checkout <branch-de-trabajo>
git pull origin <branch-de-trabajo>
git log --oneline -1            # confirmar el commit esperado

# 2) Correr en Windows
flutter run -d windows --dart-define-from-file=.env.json
```

**Reglas de oro del loop:**
- **Cambios en `router.dart`, `main.dart`, providers globales o el schema** → NO
  alcanza hot reload (`r`). Hay que **restart completo**: `q` y volver a `flutter run`
  (o Shift+R). El `GoRouter` se construye una vez en `routerProvider`.
- **Cambios de UI normal** (un widget, un texto) → hot reload (`r`) suele alcanzar.
- **Cambios de columna/tabla/sync** → seguir el checklist de integridad de AGENTS.md
  (migración en Supabase + `schema.dart` + bump `_schemaVersion` + redeploy sync rules
  + restart desde cero). Sin migración nueva ⇒ NO tocar Supabase.

### 0.2 Si hay dinero involucrado (pagos/cuotas/recibos/reportes)

Antes del testing manual, las capas automáticas (ver §4 del modelo de 4 capas en
AGENTS.md):
1. Audit estático (agentes) — ya corre en la sesión.
2. `supabase/tests/invariantes_dinero.sql` — toda fila debe dar `violaciones = 0`.
3. `flutter test` (pagos_repo y lógica crítica).

### 0.3 Checklists por feature (manual)

> Plantilla: **qué hacer → qué deberías ver → si falla**. Rubén: corregí/ampliá
> estos pasos con tu flujo real cuando algo no coincida.

- **Rechazos de sync visibles (Sprint 1, audit 2026-06-11):** desde el admin,
  editá un cliente y asignale un código que YA usa otro cliente del tenant.
  *Ver:* al sincronizar, SnackBar en español ("Código de cliente duplicado…")
  — ya no el error crudo de Postgres en inglés. En cobrador/técnico, cualquier
  cambio rechazado por el server muestra además la card ámbar **"Cambios sin
  sincronizar"** en Perfil (mensaje en español + hora local); la X descarta el
  aviso y la card desaparece sola al quedar vacía.
  *Si falla:* el detalle técnico con el contenido del cambio (opData) queda en
  `/super/logs` (error_logs).
- **Ajustes de cuota (Sprint 2, 0115):** como súper, en Configuración →
  Avanzado activá "Ajustes de cuota (admin)". Como admin, abrí un contrato →
  icono **%** en una cuota pendiente → "Aplicar ajuste" (probá monto Y
  porcentaje, con coma decimal "120,50") con motivo.
  *Ver:* preview "Saldo: X → Y" antes de confirmar; el saldo de la cuota baja
  en el contrato, en Cobros y en el mapa (mismo número); el historial de la
  cuota registra el cargo; quitar el ajuste restaura el saldo Y deja rastro
  en el historial. Con el setting OFF el icono % no aparece, y un ajuste por
  encima del tope configurado se rechaza con mensaje claro.
  *Si falla:* correr `invariantes_dinero.sql` (INV13) y revisar que 0115
  esté corrida (queries de verificación al pie de la migración).
- **Mega-sprint 2026-06-11 (smokes rápidos):** (1) en COBRO: tipeá "500,50"
  → el monto vale 500.50; back de Android con datos cargados → pide
  confirmación; aplicá un descuento manual con un cargo de reconexión
  pendiente → el total conserva la reconexión y no la duplica al confirmar.
  (2) Cancelar contrato → pide confirmación explícita. (3) Doble-click en
  "Crear cliente/contrato" → una sola entidad. (4) Como admin, filtrá "En
  mora" en /admin/cobros → el badge del cobrador NO se borra; tocá un
  cliente → abre la vista /admin con el menú lateral. (5) Menú →
  Administración → Cuotas existe y permite anular. (6) Personal → ícono 🕐
  → historial del miembro. (7) Provocá un error cualquiera → mensaje en
  español, no "Exception:". (8) Historial de cobros → "Cargar más" al fondo.
- **Cobro de campo (cobrador):** abrir una cuota pendiente → cargar monto, método,
  moneda (probar **USD con vuelto** y **C$**), foto → imprimir/guardar recibo.
  *Ver:* recibo correcto, recaudado = aplicado (no lo entregado), vuelto siempre en C$.
- **Reportes (`/admin/reportes`):** con un cobro USD y uno C$, generar Cobros, Por
  cobrador y Fiscal en **PDF y Excel**. *Ver:* "Monto/Total recaudado (C$)" = aplicado;
  columnas Moneda/Entregado/Tasa/Vuelto correctas; PDFs en landscape; Fiscal partido por moneda.
- **Recibo / impresión:** Android → botón Bluetooth; Windows → "Imprimir en impresora
  del sistema" (diálogo nativo) + "Descargar PDF" si aplica.
- **Mapa:** buscar por nombre, cédula, teléfono (con/sin guiones), código de cliente
  y de contrato → centra el pin correcto. Probar offline (tiles cacheados).
- **Transición:** navegar entre items del sidebar/nav → fade secuencial (sale una,
  entra la otra), nunca las dos encimadas.
- **Tickets — admin (`/admin/tickets`, Fase 3A):** requiere el módulo `tickets`
  encendido (super_admin en `/super/tenants/:id`). Crear un **tipo** con SLA → crear
  un **ticket** (tipo + cliente opcional + asignar a un técnico) → en el detalle,
  cambiar estado (avanzar/pausar/resolver/cerrar), reasignar, comentar, adjuntar foto.
  *Ver:* código `T-00001`, badge de estado/SLA, bitácora cronológica (creado/asignado/
  cambio de estado/comentario/adjunto), transiciones inválidas no ofrecidas. *Si falla:*
  módulo OFF → `/admin/tickets` rebota a `/admin`; admin_cobranza no lo ve.
- **Técnico (`/tecnico`, móvil-first, Fase 3B):** el super_admin asigna rol **Técnico**
  a un miembro (módulo `tickets` encendido). El admin crea un ticket y se lo asigna.
  Loguear como el técnico → entra al shell **Mis tickets · Mapa · Perfil**.
  *Ver:* en Mis tickets aparece SÓLO el ticket asignado (no otros del tenant); el detalle
  ofrece **avanzar/pausar/resolver** (no reasignar/cerrar); comentar + adjuntar foto andan;
  el Mapa muestra sólo el cliente del ticket; el Perfil NO tiene prefijo/historial/fotos.
  Probar **offline** (modo avión): mover el ticket en_progreso→en_espera→resuelto, comentar
  → al volver la red, sincroniza y el admin ve `resuelto` y puede **cerrar**. *Si falla:*
  el técnico NO debe poder entrar a `/admin`, `/super`, ni ver dinero (intentá por URL →
  rebota a `/tecnico`).
- **Materiales del ticket (3C, requiere módulos tickets + inventario):** primero, como admin,
  creá una ubicación de Inventario `tipo='técnico'` con el `cobrador_id` del técnico y
  transferíle stock (un serial + algo de granel). Como técnico (o admin), en el detalle del
  ticket → **Materiales › Agregar** → elegí serial o granel + cantidad → Registrar.
  *Ver:* aparece en la lista de Materiales + un evento "material" en la bitácora; al
  sincronizar, en Inventario el **stock baja** y el serial queda **'instalado'** en el
  cliente del ticket (visible en "Equipos instalados" del cliente y en el historial del
  serial). Probá **offline**: registrar un material sin red → al volver, el stock se
  descuenta. *Si falla:* el botón Registrar de granel debe exigir cantidad >0; un técnico
  sin custodia ve el aviso "no tenés una custodia asignada".
- **Incidentes / outages (3D, admin, módulo tickets):** con topología de red cargada
  (nodos/hubs/puertos) y clientes asignados a puertos, entrá a **Incidentes › +** → elegí
  alcance (general / nodo / hub / puerto) → Registrar. En el detalle: *ver* los **clientes
  afectados** correctos (los que cuelgan de ese nodo/hub/puerto), agregá tickets vía el
  picker al crear un ticket o con **"Vincular a incidente"** en un ticket existente, y
  **resolvé**. *Ver:* el alcance sigue mostrándose aunque borres el puerto/hub/nodo
  (snapshot); un técnico NO puede entrar a `/admin/incidentes` (rebota) ni ve el incidente
  en su ticket. *Si falla:* el corte general lista TODOS los clientes activos; un corte por
  puerto, sólo los de ese puerto.
- **Cancelar contrato = saldo a 0 (admin, detalle de contrato):** requiere correr las
  migraciones `0111` + `0112`. En `/admin/contratos/:id` (o `/contratos/:id`), tocá el badge
  de estado → **Cancelado**.
  - *Contrato con cuotas pendientes (sin pagar):* tras cancelar → **desaparecen** de "por
    cobrar" (lista del cobrador, `/admin/cuotas`, dashboard, mapa); el resumen muestra **"Total
    recaudado" / Pendiente 0**; en la lista de cuotas del contrato quedan **anuladas** (tachadas).
  - *Contrato con una cuota PARCIAL (cobrá parte de una cuota primero):* tras cancelar → el
    pago **sigue contado** en Recaudado (resumen + `/admin/pagos`); la cuota pasa a **pagada**
    (saldo 0) y desaparece de "por cobrar"; en el **Historial** de la cuota aparece un descuento
    "Saldo cancelado por baja del contrato". Probá **offline** (modo avión): el saldo da 0 **al
    instante** (no espera el sync).
  - *Contrato en mora:* tras cancelar → la **mora se limpia** (panel `/admin/notificaciones` +
    badge del cobrador), tras el sync.
  - *B2 terminal:* en un contrato ya **cancelado**, el badge de estado **no** abre dropdown (no
    se reactiva). En el **form de edición** del contrato **no** hay switch de estado.
  - *A3 impersonación:* como super_admin impersonando un tenant, el dropdown de estado **no**
    ofrece "Cancelado"; si llega a dispararse, sale un mensaje de bloqueo.
  - *Si falla:* correr `supabase/tests/invariantes_dinero.sql` → toda fila `violaciones = 0`. Un
    saldo ≠ 0 en alguna pantalla para el contrato cancelado, o un recaudado que cambió, es bug.
- **Colores configurables de estados de cuota (admin, Ajustes → Cobranza):** abrir
  **Ajustes → Cobranza → "Colores de estados de cuota"** → tocar una fila (ej. "En mora") →
  elegir un color de la paleta. *Ver:* el color cambia **en vivo** en el **mapa** (pin), en la
  **lista de cobros** (badge), en **cuotas admin**, en el **detalle de contrato** y en la
  **lista de clientes**; reabrir Ajustes → el swatch quedó con el color elegido. *Si falla:* si
  no se refleja, fijate que salió el snackbar "Color de X actualizado" (es reactivo, no requiere
  reiniciar). No hay migración: en un tenant sin la clave aplican los defaults 🔴 mora /
  🟠 gracia / 🔵 vence-hoy / 🟣 próxima.
- **Mapa — 6 estados + gate por rango (cobrador vs admin):** abrir el mapa. *Ver (cualquiera):*
  pines coloreados por la cuota MÁS urgente del cliente — 🔴 mora, 🟠 gracia, 🔵 vence hoy,
  🟣 próxima (vence dentro de `cobranza.dias_cuotas_visibles`); chips **Pendientes / En mora /
  En gracia / Vencen hoy / Próximas** con su puntito de color. *Ver (cobrador):* NO aparecen los
  clientes sin deuda ni los de cuota fuera de rango. *Ver (admin):* aparece además el chip
  **"Ver todo"** → trae los de fuera de rango (morado atenuado) y sin deuda. *Si falla:* si ves
  pines verdes o TODOS los clientes por defecto, no recompiló (q + flutter run desde cero).
- **Lista de cobros — "Próximas" + "Ver todo" (admin):** en "Por cobrar", *ver:* chip
  **"Próximas"** (vencen después de hoy, dentro del rango) y badges "por vencer" en **morado**.
  Como admin en **`/admin/cobros`** aparece además **"Ver todo"** → TODO lo pendiente sin el
  límite de rango (las cuotas lejanas que el cobrador no ve). *Si falla:* el cobrador NO debe ver
  el chip "Ver todo".
- **Banner "sin conexión" sin parpadeo:** usar la app con red estable, navegar entre pantallas,
  cambiar de tenant (super_admin). *Ver:* el banner rojo "Sin conexión" **no parpadea**. Para el
  real: **modo avión** ~5s → aparece a los ~3s; **sacar modo avión** → desaparece sin flickear.
  *Si falla:* si parpadea al navegar o al cambiar de DB/tenant, el guard del estado de carga no
  está activo.
- **Settings sensibles solo super (Ajustes, requiere 0113):** como **admin del ISP** (no super), en
  Ajustes → Cobranza NO deben aparecer "Permitir pago parcial", "Permitir pago adelantado", "Cobrador
  anula/edita cobros" (se movieron a Avanzado), ni sueltos en "Otros". Como **super_admin**, Ajustes →
  **Avanzado** muestra "Reglas de cobro avanzadas" + "Permisos del cobrador". *Si falla:* correr 0113
  (marca `editable_por='super_admin'` → la RLS también los bloquea, no solo la UI).
- **Días de cuotas próximas configurable (requiere 0113):** Ajustes → Cobranza muestra **"Días de cuotas
  próximas" = 5**. Subilo a, ej., 15 → en el detalle de contrato/mapa, las cuotas que vencen dentro de 15
  días pasan a "en rango" (color); las de más allá quedan **grises**. *Si falla:* si no aparece el campo,
  la fila no se sembró (correr 0113).
- **Cuotas fuera de rango = gris (detalle de contrato):** abrí un contrato con cuotas futuras lejanas.
  *Ver:* las dentro de "días de cuotas próximas" → morado/azul/etc.; las **lejanas → GRIS "no disponible"**
  (antes salían todas en morado). *Si falla:* una cuota a meses en morado = el rango no se aplica.
- **Depósito quitado:** Ajustes → Pagos ya NO tiene "Aceptar depósitos"; en un cobro los métodos son
  efectivo / transferencia / tarjeta. *Ver:* los pagos viejos con método "Depósito" siguen en
  historial/reportes/arqueo (data histórica preservada).
- **Recibo — zonas + reset (Ajustes → Recibos):** *Ver:* **WhatsApp** en el **Encabezado**; cada bloque
  tiene un menú **⋮ "Mover a zona"** (Encabezado/Cuerpo/Pie) → moverlo se refleja en la vista previa y en
  el recibo impreso; el botón **"Restaurar layout por defecto"** vuelve al orden base (con confirmación).
  *Si falla:* si WhatsApp sigue en el pie, usá "Restaurar layout por defecto" o el menú ⋮.
- **⟨agregar acá los features nuevos a medida que se entregan⟩**

---

## 1. Setup del backend en Supabase

### 1.1 Crear el proyecto Supabase

1. Crear proyecto en supabase.com.
2. En **Settings → Auth**: habilitar Email/Password.
3. En **Settings → API**: copiar `URL` y `anon key` a `.env.json`.

### 1.2 Correr las migraciones

En **SQL Editor**, corré en orden los archivos de `supabase/migrations/`:

```
0001_init.sql                          → 0010_settings_defaults.sql
0011_fixes_settings_pk_misc.sql        → 0020_audit_log.sql
0021_anulacion_cuotas.sql              → 0025_fix_b2_reasignacion_offline.sql
```

25 archivos en total. Cada uno debe terminar sin errores.

### 1.3 Correr el smoke test

```sql
-- pegar y ejecutar supabase/smoke_test.sql
```

Debe terminar con `✅ smoke test OK`. Si falla, el error indica qué migración revisar.

### 1.4 Configurar PowerSync

1. En el dashboard de PowerSync: crear instancia conectada a tu Supabase.
2. En **Sync Rules**: pegar el contenido de `powersync/sync-rules.yaml`.
3. Marcar "Use Supabase Auth" en la sección de credenciales.
4. Copiar el `powersync URL` a `.env.json`.

---

## 2. Setup de la app Flutter

### 2.1 Generar plataformas nativas

```bash
flutter create . --platforms=android,ios,web
flutter pub get
```

### 2.2 Configurar permisos nativos

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>

<!-- Bluetooth para impresora térmica -->
<uses-permission android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
```

**iOS** — agregar también en `Info.plist`:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
```

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Capturamos tu ubicación al registrar un cobro para auditoría.</string>
<key>NSCameraUsageDescription</key>
<string>Para tomar foto del comprobante de pago y del cliente.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Para adjuntar foto desde galería.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
```

### 2.3 Levantar en cada plataforma

```bash
# Mobile (cobrador)
flutter run --dart-define-from-file=.env.json

# Web (admin)
flutter run -d chrome --dart-define-from-file=.env.json
```

---

## 3. Smoke test manual del flujo

### 3.1 Crear usuarios

Desde la **app web** (recomendado):

1. Abrí la app web (admin), tocá "Crear cuenta nueva".
2. Email, contraseña, tu nombre, nombre de tu empresa.
3. Confirmá email si Supabase lo exige.
4. Logueate → llegás al wizard de onboarding.

El trigger `handle_new_user` (migración 0024) crea el tenant + tu fila
como admin automáticamente.

Para sumar más usuarios (admin_cobranza / cobrador), una vez logueado:
- `/admin/cobradores` → botón "Invitar nuevo".
- Ingresá email, nombre, rol y prefijo (si cobrador).
- La Edge Function `invitar-cobrador` los envía por email.

### 3.2 Correr el seed demo (opcional, sólo si querés data de prueba)

Si querés probar con clientes pre-cargados, abrí `supabase/seed_demo.sql`,
pegá los 3 UUIDs de auth.users en las variables de la cabecera
y ejecutalo. Crea:

- 1 tenant
- 3 cobradores con sus roles
- 5 municipios y 10 comunidades
- 3 planes
- 12 clientes con geo
- 8 contratos (mix de duraciones)
- Pagos variados (completos, parcial, USD, anulado)

### 3.3 Test del panel admin (web)

Loguear como `admin@test.com` en la app web.

**Checklist**:
- [ ] Redirect a `/admin` automático
- [ ] Dashboard muestra KPIs (cobrado mes, clientes activos, en mora)
- [ ] `/admin/clientes`: lista de 12 clientes
- [ ] Filtro por comunidad funciona
- [ ] Bulk-assign: seleccionar 3, pedir confirmación, asignar a Pedro
- [ ] `/admin/clientes/nuevo`: crear cliente con foto + GPS picker en mapa
- [ ] `/admin/contratos`: lista de 8 contratos con progreso de cuotas
- [ ] `/admin/contratos/:id/editar`: cambiar día de pago → cuotas futuras se actualizan
- [ ] `/admin/planes`: ver los 3 planes, crear uno nuevo
- [ ] `/admin/cobradores`: ver los 3 cobradores, editar prefijo
- [ ] `/admin/cuotas`: filtrar por estado, anular una cuota con motivo
- [ ] `/admin/pagos`: anular un pago, ver que la cuota baja a `parcial`
- [ ] `/admin/notificaciones`: ver mora pendiente, marcar como vista
- [ ] `/admin/settings`: cambiar tasa USD, ver que se guarda
- [ ] `/admin/audit`: ver el audit log con los cambios anteriores
- [ ] `/admin/geografia`: explorar el árbol depto → municipio → comunidad
- [ ] `/admin/reportes`: ver recaudación, ranking cobradores, mora

### 3.4 Test offline cobrador (mobile)

Loguear como `cobrador@test.com` en la app móvil.

**Checklist conectado**:
- [ ] Home muestra dashboard con métricas del cobrador (no de todos)
- [ ] `/clientes`: ve solo SUS clientes asignados (Pedro tiene los 12 del seed)
- [ ] `/cuotas`: lista de cuotas pendientes con filtros
- [ ] Detalle cliente: ver llamar / WhatsApp / navegar
- [ ] `/cobro/:id`: cobrar parcial 200 de 500 → estado pasa a `parcial`
- [ ] Recibo se muestra con período correcto (regla del 15 sobre día de pago)
- [ ] Aplicar descuento de 10% antes de cobrar → total se ajusta

**Checklist offline** (apagar internet en el teléfono):
- [ ] Banner rojo "Sin conexión" aparece arriba
- [ ] Sigue navegando, viendo clientes y cuotas
- [ ] Hace 2-3 cobros offline (uno con foto del comprobante)
- [ ] Cada recibo se genera con correlativo + número completo
- [ ] Encender internet → banner desaparece
- [ ] Sync indicator del AppBar muestra "uploading" → "synced"
- [ ] Las fotos pendientes en `/perfil` se suben (badge desaparece)
- [ ] En la web del admin, los cobros aparecen

### 3.4.1 Test de impresión Bluetooth (mobile)

**Pareo previo desde el sistema**:
1. Encender la impresora térmica (típico botón POWER con LED).
2. En Ajustes → Bluetooth del teléfono, parear la impresora (ej. POS-58, MTP-3, etc.).

**En la app**:
- [ ] `/perfil` muestra card "Impresora térmica" con "Sin configurar"
- [ ] Tocar → `/perfil/impresora`
- [ ] Si BT off: card rojo "Bluetooth desactivado, encendelo y refrescá"
- [ ] BT on: lista de pareadas aparece
- [ ] Menú "..." → "Imprimir prueba" → sale ticket "PRUEBA DE IMPRESIÓN" con fecha/hora
- [ ] Menú "..." → "Usar como predeterminada" → snackbar de confirmación
- [ ] Card superior cambia a "Impresora predeterminada: <nombre>"
- [ ] `/perfil` card ahora muestra el nombre (no "Sin configurar")
- [ ] En el flujo de cobro: tras confirmar, en `/recibo/:id` botón "Imprimir 80mm" funcional
- [ ] Imprime con header (empresa), info recibo, cliente, servicio, total destacado, pie libre, corte
- [ ] Reimpresión: tocar imprimir otra vez → ticket sale con "*** REIMPRESIÓN ***" al final
- [ ] BD: `recibos.impreso_en` y `reimpresiones` se incrementan

### 3.5 Test de RLS (seguridad)

Desde Supabase SQL Editor, **logueate como uno de los cobradores** (en
`Authentication → Users → user → Generate JWT` y usá ese JWT).

Intenta:

```sql
-- ¿El cobrador puede UPDATE cliente de otro cobrador?
update clientes set nombre = 'HACKEADO' where cobrador_id != auth.uid() limit 1;
-- Esperado: 0 filas afectadas o error.

-- ¿Puede UPDATE su propio rol a admin?
update cobradores set rol = 'admin' where id = auth.uid();
-- Esperado: error (sólo admin puede).

-- ¿Puede UPDATE monto de una cuota?
update cuotas set monto = 1 where cobrador_id = auth.uid() limit 1;
-- Esperado: error del trigger cuotas_check_cobrador_update.

-- ¿Puede mutar correlativo de su recibo?
update recibos set correlativo = 999 where cobrador_id = auth.uid() limit 1;
-- Esperado: error del trigger recibos_check_cobrador_update.
```

Las 4 queries deben fallar o devolver 0 filas. Si alguna se ejecuta, hay
una grieta en RLS.

### 3.6 Test del cron mensual

```sql
-- Forzar la generación de cuotas para el mes próximo (en lugar de esperar al 1 del mes):
select generar_cuotas_mes(t.id, (current_date + interval '1 month')::date)
  from tenants t where nombre = 'ISP Demo Managua';
-- Devuelve cantidad de cuotas creadas.

-- Forzar el cálculo de notificaciones de mora:
select actualizar_notificaciones_mora(t.id) from tenants t where nombre = 'ISP Demo Managua';
-- Devuelve cantidad de notificaciones afectadas.
```

---

## 4. Troubleshooting frecuente

| Síntoma | Causa probable | Fix |
|---|---|---|
| App móvil queda en spinner tras login | Sync rules mal copiadas o cobrador sin fila en `cobradores` | Verificar que el UUID del seed coincide con auth.users |
| `flutter run` falla en web por `dart:io` | Conditional import roto | Confirmar que `foto_local_storage.dart` exporta con `if (dart.library.html)` |
| Cron no genera cuotas | pg_cron deshabilitado en tu plan Supabase | Activarlo o llamar manualmente la función |
| Botón "Cobrar" disabled siempre | Cobrador sin `prefijo_recibo` asignado | Admin va a `/admin/cobradores` y le asigna uno |
| Foto del comprobante no se sube | Sin internet O policy Storage incorrecta | Ver indicador en perfil; verificar 0019 y 0022 |
| Recibo dice mes incorrecto | Bug pre-fix S1; reverificar | Confirmar que migración 0014 está aplicada |

---

## 5. Notas conocidas

- **Auto-creación de cobradores**: hoy el admin invita desde Supabase Dashboard
  y luego asigna prefijo desde `/admin/cobradores`. Una Edge Function para
  automatizar esto está pendiente.
- **Impresión Bluetooth**: el preview del recibo funciona; el botón "Imprimir"
  está disabled hasta integrar `print_bluetooth_thermal`. El recibo igual
  se sincroniza al server.
- **Audit log offline**: las funciones SECURITY DEFINER del cron corren como
  postgres (sin auth.uid), así que las notificaciones generadas por cron
  tienen `user_id = NULL`. El viewer las muestra como "Sistema".
