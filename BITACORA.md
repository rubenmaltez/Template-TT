# BITACORA.md — Control de cambios y estado vivo del proyecto

> **Quién lee esto:** la PRIMERA lectura de toda sesión nueva (humano o AI).
> Responde "¿dónde quedamos, qué fue lo último que se trabajó y por qué?".
> **Cómo se actualiza (OBLIGATORIO al cerrar cada sesión de trabajo):**
> 1. Refrescar el bloque **ESTADO ACTUAL** (branch, commit, pendientes).
> 2. Agregar una **entrada nueva ARRIBA** de las demás con el formato:
>    `## AAAA-MM-DD — título` + qué se pidió/por qué + qué se hizo (con
>    commits y archivos clave) + qué quedó pendiente + deploy necesario.
> 3. Si el cambio tocó módulos/conexiones → actualizar también
>    `ARQUITECTURA.md`. Si tocó misión/roles/stack → `PRODUCTO.md`.
> Mantener cada entrada en ≤15 líneas. El detalle fino vive en los commits.
> **Documentos hermanos:** `PRODUCTO.md` (qué es la app) · `ARQUITECTURA.md`
> (cómo está conectada) · `AGENTS.md` (reglas/proceso) · `Install Steps/`
> (build y release) · `TESTING.md` (testing manual).

---

## ⭐ ESTADO ACTUAL (refrescar al cerrar cada sesión)

- **Branch viva: `main`** (única rama permanente; default del repo en GitHub).
  Checkpoints históricos = **tags**: `pre-mvp-v2` (estado auditado 2026-06-09)
  y `pre-mvp-v1` (checkpoint previo).
- **Modelo de branching:** cada sesión de trabajo crea su rama efímera
  (`claude/*` o feature) DESDE `main` → al terminar se mergea a `main` y la
  rama se BORRA. Hitos importantes se marcan con tag, no con rama.
- **App:** v0.10.0 · schema PowerSync **v26** · migraciones **0001→0114
  TODAS corridas** en Supabase (verificado 2026-06-09) · sync rules v26 activas.
- **Edge Functions:** las 6 deployadas al día (incl. `eliminar-cobrador` con
  conteos extendidos y `_shared/passwords.ts` sin sesgo, redeployadas 2026-06-09).
- **Qué falta:** `flutter pub get` (lock) · generar keystore de release (guía
  0-Setup §3b) · smoke tests B.2–B.6 + updater (entrada 2026-06-10) · publicar
  release nuevo y borrar `v0.9.0`.
- **Salud:** audit integral 2026-06-09 → **sin CRITICAL/HIGH abiertos**;
  14/14 findings resueltos o aceptados con justificación.

---

## 2026-06-10 — Auto-update in-app + fix de firma del APK + limpieza de releases

**Por qué:** el banner de update delegaba la descarga al browser — en Android
Chrome nunca completaba la descarga (moría en los redirects de GitHub) y en
Windows quedaba en Descargas con instalación manual. Rubén eligió la opción A
(updater in-app, GitHub sigue de host; la opción B —Supabase Storage, que
permitiría repo privado— quedó documentada como alternativa futura).

**Qué se hizo (commits `fc1583a` + `2fdcb3c` + `66e09e5`):**
- **Updater in-app**: la app descarga el binario ella misma (http streamed,
  timeout 30s handshake + por-chunk, progreso 0-100% en el banner, errores en
  español con Reintentar + plan B "Navegador") y lanza el instalador del
  sistema vía `open_filex` (+1 dep): Android → diálogo "¿Instalar?" (permiso
  `REQUEST_INSTALL_PACKAGES` runtime, 1 toggle la 1ª vez), Windows → App
  Installer. Web mantiene fallback browser. Estado `_instalando` evita doble
  descarga. Archivos: `update_service.dart`, `update_banner.dart`, manifest.
- **Fix CRÍTICO de firma del APK** (encontrado por el audit de plataforma):
  el release firmaba con la **debug key de la PC** → un APK de otra PC no
  podía actualizar instalaciones existentes (y "arreglarlo" = desinstalar =
  perder la DB offline del cobrador). Ahora `build.gradle.kts` firma con
  keystore dedicado (`android/key.properties` + `sitecsa-release.jks`,
  LOCALES — gitignored) con fallback a debug para dev. **Rubén debe generar
  el keystore 1 vez** (pasos en `Install Steps/0-Setup-PC-desarrollo.md` §3b).
  ⚠️ Transición: el PRÓXIMO release tendrá firma nueva → las apps ya
  instaladas (firmadas debug) deben desinstalar/reinstalar UNA vez (sincronizar
  antes). Después, updates normales para siempre.
- **Releases viejos limpiados** (con Rubén, gh CLI): quedó solo `v0.9.0`
  (endpoint vivo del auto-update) + tags `pre-mvp-v1/v2`. 18 releases borrados.
- **Pendiente (Rubén):** `flutter pub get` (lock con open_filex) → generar
  keystore → smoke tests B.2-B.6 + flujo del updater → publicar release nuevo
  (`v0.11.0`) → borrar `v0.9.0`.

## 2026-06-09 (e) — Limpieza de PC local + setup multi-PC

**Por qué:** la carpeta local de Rubén tenía restos de versiones anteriores;
y quiere poder trabajar desde otras PCs con solo `git clone`.

**Qué se hizo:**
- Carpeta local limpiada con `git clean -fdx` (dry-run revisado; exclusiones:
  `.env.json`, `Releases\`, cert y DLLs) → working tree = `main` exacto.
- **Binarios de soporte AL repo** (cambio de `.gitignore`): `powersync.dll` /
  `powersync_x64.dll` (core nativo para los tests de dinero en Windows) y
  `SITECSA-CRM.cer` (cert PÚBLICO del MSIX — no es secreto). `.env.json`
  sigue SIEMPRE fuera de git (keys; a PC nueva va por canal seguro).
- **`Install Steps/0-Setup-PC-desarrollo.md`** (nuevo): guía completa de PC
  de dev nueva (herramientas → clone → .env.json → pub get → run → tests →
  gh para releases). La firma MSIX usa el cert de prueba del paquete `msix`
  (sin certificate_path) → releases compatibles desde cualquier PC.
- `pubspec.lock` actualizado (faltaba `mobile_scanner` — pendiente viejo).

## 2026-06-09 (d) — Consolidación de ramas: main + tags pre-mvp

**Por qué:** había 4 ramas en GitHub (2 de Claude viejas, el checkpoint
`pre-mvp-v1`, y la default era una rama muerta `claude/plan-billing-app-q9mC4`)
— confuso para sesiones futuras y para ver el código actual en GitHub.

**Qué se hizo (decisión de Rubén — opción A):**
- **`main`** creada desde el estado auditado (todo el trabajo del 2026-06-09)
  → **única rama permanente y default del repo**.
- Checkpoints convertidos a **tags inmutables**: `pre-mvp-v2` (= este estado,
  audit integral + fixes + docs rework) y `pre-mvp-v1` (= `48111e5`, el
  checkpoint previo).
- **Borradas** todas las demás ramas: `claude/hopeful-ride-u1ivz5`,
  `claude/new-features-inventory-tickets-and-technicians`, `pre-mvp-v1`,
  `claude/plan-billing-app-q9mC4`.
- Modelo de branching documentado acá (§ESTADO ACTUAL) y en `AGENTS.md`
  (§Git/branching): ramas efímeras desde `main` → merge → borrar; hitos = tags.
- **`AGENTS.md` = LA fuente única de reglas** (decisión de Rubén, patrón
  oficial de Claude Code): todas las reglas/invariantes/proceso viven en
  `AGENTS.md` (estándar que leen OpenCode/Codex/Cursor/Antigravity directo);
  `CLAUDE.md` quedó como shim de 1 línea (`@AGENTS.md`) solo para que Claude
  Code lo cargue automáticamente. Las referencias de los demás docs apuntan
  a `AGENTS.md`. NO editar reglas en CLAUDE.md.

## 2026-06-09 (c) — Rework del sistema de documentación + build a Install Steps

**Por qué:** pedido de Rubén (prioridad máxima): que cualquier modelo futuro
pueda hacer cambios SIN escanear todo el código, con docs que se
auto-referencien y se mantengan al día.

**Qué se hizo:**
- Nuevo sistema de 4 docs activos en la raíz: `PRODUCTO.md` (misión/visión/
  día-a-día/stack+porqués) · `ARQUITECTURA.md` (rework: esquema dual
  humano/AI, módulo por módulo con conexiones + **recetas de cambios
  comunes**) · `BITACORA.md` (este archivo) · `AGENTS.md` (adelgazado: reglas/
  proceso/invariantes + índice maestro).
- `build-release.ps1` movido de la raíz a **`Install Steps/`** (con auto-cd a
  la raíz del repo para que las rutas relativas sigan funcionando);
  referencias actualizadas.
- Docs históricos movidos a **`docs/archive/`** (HANDOFF, REPORTE-SESION,
  ESTADO-APP, STACK, ROADMAP, planes BULK/FASE3, audits, RELEASE) con README
  índice. Nada se borró: historia completa en archive + git.

## 2026-06-09 (b) — Audit integral profundo + TODOS los findings resueltos + deploy

**Por qué:** pedido de Rubén: audit completo de lógica de módulos +
interacciones + conformidad con lifecycle/misión, y resolver todo.

**Qué se hizo (commits `2917a73` → `d31bbb8` → `9f60ab9` → `8eb19e9` → `3f162eb`):**
- **Audit 6 agentes** (dinero, offline-first, change log, inventario/tickets,
  multi-tenant/seguridad, integridad estructural) → veredicto: app sólida,
  sin CRITICAL/HIGH. 6 MEDIUM + 8 LOW, **todos atacados**.
- Fixes clave: lock de `connectPowerSync` (cierra el sync-gate-stuck
  post-forzar-password) · clase 40 retryable en el connector · SLA de tickets
  sin corrimiento de 6h post-sync (`parseTicketWallClock`) · mirror local de
  cargos (saldo correcto offline) · migración **0114** (gate de módulos
  server-side: escritura de inv_*/tickets/incidentes + storage exige
  `tenant_tiene_modulo`) · `eliminar-cobrador` con 12 conteos nuevos tolerante
  a `PGRST205` · `HistorialTicketWidget` (agregador) · UploadResult de fotos
  persistido · password sin sesgo de módulo · viewer de audit ordena por
  `ocurrido_en`.
- **Audit final** (3 agentes sobre todo el diff): sin gaps de código.
- **Deploy verificado CON Rubén:** migraciones 0099→0112 confirmadas corridas
  (tablas 15/15, columnas 6/6, triggers 7/7) · 0114 corrida y verificada
  (~19 policies con el gate) · 4 edge functions redeployadas.
- **Pendiente:** smoke tests en la app — B.2 regresión 0114 con módulo ON ·
  B.3 forzar-password sin F5 · B.4 cargo offline · B.5 SLA estable tras sync ·
  B.6 historial del ticket.

## 2026-06-09 (a) — Checkpoint pre-MVP v1 (sesiones anteriores)

Estado al cierre de la ventana anterior: colores configurables de estados de
cuota across-app (6 estados, gate por rango del cobrador) · limpieza de
settings + recibo con zonas + "Restaurar layout" · fix pantalla negra del
reset · menú Pagos respetando setting para el super. Migración 0113 corrida.
Branch checkpoint: `pre-mvp-v1` (commit `48111e5`).

## Historia anterior (resumen telegráfico — detalle en `docs/archive/`)

- **2026-06-08:** audit integral multi-agente (11 agentes) + cancelar contrato
  = saldo 0 + 16 commits de fixes. Migraciones 0111/0112.
- **2026-06-05→07:** Fase 3 completa (tickets 3A→3E: técnico, materiales,
  incidentes, SLA offline) + inventario v2 + red. Schema v17→v26.
- **2026-06-04→06:** impresión térmica resuelta (GS v 0) · mapa offline ·
  reportes Excel/PDF · distribución Windows/Android (MSIX/APK + auto-update).
- **2026-05-23→06-03:** fundación: multi-tenant + RLS + PowerSync per-user ·
  invariantes de dinero + fix del vuelto · change log universal · impersonación
  · BULK 11/12 (multi-cuota, UX admin) · hardening de Edge Functions.

---

## 📌 Backlog vivo (lo REALMENTE pendiente — no re-flagear lo resuelto)

**Operativo (Rubén):**
- Smoke tests B.2–B.6 (ver entrada 2026-06-09 b).
- `flutter analyze` + `dart format` en el próximo build local.

**LOW / cuando toque (con contexto en `docs/archive/AUDIT-INTEGRAL-2026-06-09.md`):**
- Completar o eliminar el rol `admin_tickets` (hoy no se ofrece; decisión de producto).
- Tests: widget + integración + redirects del router (hoy 0).
- `/super/logs`: filtro de fechas + cron de retención >90d.
- `reenviar-invitacion`: lock delete→create (solo afecta con 2+ super_admins).
- Edge cases teóricos documentados: cross-tab sin sync, race autoDispose entre
  tenants, PKCE recovery user-switch, `lastSyncedAt` semantics.
- Config de distribución de producción: applicationId, cert, deep-links.

**Parqueados por decisión de Rubén:** flags `modo_ruta`/`caja_chica` (ocultos) ·
geo del cobro · Resend/dominio (externo).
