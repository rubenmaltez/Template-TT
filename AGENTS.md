# AGENTS.md — Instrucciones para CUALQUIER agente de AI

> Este repo es **Cobranza ISP (SITECSA CRM)**: SaaS multi-tenant de cobranza
> para ISPs, Flutter + Supabase + PowerSync (offline-first). Si sos Claude
> Code, ya cargaste `CLAUDE.md` automáticamente. Si sos OTRA herramienta
> (OpenCode, Codex, Cursor, Antigravity, Gemini, etc.): **este archivo es tu
> punto de entrada.**

## ORDEN DE LECTURA OBLIGATORIO (antes de tocar código)

1. **`BITACORA.md`** — ¿dónde quedamos? Estado vivo, último trabajo y por qué,
   backlog real. SIEMPRE primero.
2. **`CLAUDE.md`** — las REGLAS completas del proyecto: invariantes de dinero,
   principios, checklists de audit, proceso de trabajo (fases 1-6), deploy.
   Aplican a CUALQUIER agente, no solo a Claude.
3. **`PRODUCTO.md`** — qué es la app, roles, día a día, stack y porqués
   (contexto de negocio).
4. **`ARQUITECTURA.md`** — para hacer CUALQUIER cambio: empezá por su **§0
   (índice "quiero cambiar X → andá a Y")** y seguí la receta (R1-R12).
   Esto evita escanear todo el repo.

## REGLAS MÍNIMAS INQUEBRANTABLES (resumen — detalle en CLAUDE.md)

- **Dinero**: NUNCA violar las 10 invariantes de `CLAUDE.md`. Recaudado =
  `SUM(pagos.monto_cordobas)` no anulados; el vuelto SIEMPRE en córdobas;
  `cuota.monto_pagado` lo mantiene un trigger server (el cliente solo espeja).
- **Multi-tenant**: toda tabla operativa nace con `tenant_id` + RLS
  (`current_tenant_id()`) + policy `super_admin_all` + trigger de audit.
- **Offline-first + server gana**: el cobrador opera sin internet; Postgres
  es la verdad; el cliente espeja triggers solo para UX instantánea.
- **SQLite ≠ Postgres**: en `lib/` NO se usa `FILTER`, `::casts`, `ILIKE`,
  `RETURNING`. Límites de día SIEMPRE con `date('now','-6 hours')` (Nicaragua
  UTC-6) — nunca `date('now')` pelado.
- **Cadena de integridad** al tocar tablas/columnas: migración →
  `schema.dart` → bump `_schemaVersion` → redeploy sync rules → Dart.
  (Receta R4/R10 de ARQUITECTURA.md.)
- **Branching**: `main` es la única rama permanente. Trabajá en una rama
  efímera desde `main` → merge → borrar la rama. Hitos = tags. Sin force-push.

## AL CERRAR TU SESIÓN (obligatorio, no saltear)

1. Actualizá **`BITACORA.md`**: bloque ESTADO ACTUAL + entrada nueva arriba
   (qué se pidió, qué se hizo, commits, pendientes).
2. Si cambiaste un módulo/tabla/setting/ruta/conexión → actualizá
   **`ARQUITECTURA.md`** (sección del módulo y/o recetas).
3. Si cambió misión/roles/stack → `PRODUCTO.md`.
4. Para guiar el build/release de una versión nueva:
   `Install Steps/1-Publicar-nueva-version.md`.

## Idioma y estilo

Español (rioplatense, "vos"). Strings de UI 100% en español. Commits en
español, primera línea ≤72 chars, sin firmas ni co-authored-by. Comunicación
con Rubén: pasos detallados, un comando por vez, con output esperado.
