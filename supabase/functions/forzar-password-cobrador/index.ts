// Edge Function: forzar-password-cobrador
//
// Permite al super_admin asignar directamente una contraseña a otro usuario,
// sin pasar por el flujo de email (útil cuando el cliente no tiene acceso al
// email o cuando hay rate limits). El super_admin comunica la contraseña
// por canal seguro (Whatsapp, en persona).
//
// Guards:
//   - Sólo super_admin (rol en cobradores).
//   - No puede modificarse a sí mismo.
//   - No puede modificar a otro super_admin.
//   - Password mínimo 8 caracteres (alineado con default de Supabase).
//
// Después de actualizar la password registra en audit_log SIN guardar el
// valor — sólo flag de que el super_admin forzó el cambio.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";

interface ForzarPasswordRequest {
  cobrador_id: string;
  nueva_password: string;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonError("Authorization header faltante", 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Cliente con el JWT del caller — para identificar quién está pidiendo.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar que el caller es super_admin.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede forzar contraseñas", 403);
    }

    // Validar body.
    const body: ForzarPasswordRequest = await req.json();
    if (!body.cobrador_id || !body.nueva_password) {
      return jsonError(
        "cobrador_id y nueva_password son requeridos",
        400,
      );
    }
    if (body.nueva_password.length < 8) {
      return jsonError(
        "La contraseña debe tener al menos 8 caracteres",
        400,
      );
    }

    if (body.cobrador_id === user.id) {
      return jsonError(
        "No podés forzar tu propia contraseña — usá el flujo normal",
        400,
      );
    }

    // Cliente con service_role para validar target + auth.admin.update.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: target, error: tgtErr } = await admin
      .from("cobradores")
      .select("id, tenant_id, rol")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tgtErr) {
      // No filtramos el mensaje del DB al cliente — log server-side y
      // mensaje genérico afuera.
      console.error("forzar-password: tenant lookup failed", tgtErr);
      return jsonError("Error interno verificando el usuario", 500);
    }
    if (!target) return jsonError("Cobrador no existe", 404);
    if (target.rol === "super_admin") {
      return jsonError(
        "No se puede modificar la contraseña de otro super_admin",
        400,
      );
    }

    // Intent/success split. Dos rows en audit_log:
    //   1. ANTES del update: action='force_password_reset_intent'.
    //      Si el insert falla, abortamos sin aplicar el cambio.
    //      Si el insert OK pero el update falla, el intent queda como
    //      rastro de que se intentó (timeline muestra el intent solo).
    //   2. DESPUÉS del update exitoso: action='force_password_reset_success'.
    //      Si el insert success falla, log loud (el cambio ya está
    //      aplicado, no podemos rollback; el operador investigará
    //      por server logs).
    //
    // Esto resuelve el problema de "audit-first" donde una sola row
    // de "reset" se muestra aunque la operación falle: el timeline
    // distinguía mal éxito de intento. Append-only se mantiene.
    // NUNCA guardamos la password en ninguno de los rows.
    const { error: intentErr } = await admin.from("audit_log").insert({
      tenant_id: target.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "encrypted_password",
      valor_anterior: null,
      valor_nuevo: { action: "force_password_reset_intent" },
      user_id: user.id,
      user_rol: "super_admin",
    });
    if (intentErr) {
      console.error("forzar-password: intent audit insert falló", intentErr);
      return jsonError(
        "No se pudo registrar la auditoría — el cambio no se aplicó. " +
          "Reintentá en unos segundos.",
        500,
      );
    }

    // Actualizar password vía auth.admin (única vía sin email).
    const { error: updErr } = await admin.auth.admin.updateUserById(
      body.cobrador_id,
      { password: body.nueva_password },
    );
    if (updErr) {
      // El intent row queda en audit_log como evidencia del intento
      // fallido — el operador puede ver "intentó pero no se aplicó"
      // sin que el timeline mienta diciendo que pasó.
      console.error(
        "forzar-password: updateUserById falló DESPUÉS de intent audit. " +
          `cobrador_id=${body.cobrador_id}. Timeline mostrará solo el intent.`,
        updErr,
      );
      return jsonError(humanizeAuthError(updErr.message), 400);
    }

    // Cambio aplicado — registramos el success.
    const { error: successErr } = await admin.from("audit_log").insert({
      tenant_id: target.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "encrypted_password",
      valor_anterior: null,
      valor_nuevo: { action: "force_password_reset_success" },
      user_id: user.id,
      user_rol: "super_admin",
    });
    if (successErr) {
      // Cambio aplicado pero success audit perdido. Log loud — el
      // intent row da pista de que algo intentó, pero el operador
      // tiene que verificar manualmente si se aplicó.
      console.error(
        "forzar-password: success audit insert FALLÓ — password sí " +
          `cambió, intent row está, success row NO. ` +
          `cobrador_id=${body.cobrador_id}`,
        successErr,
      );
    }

    // Invalidar todas las sesiones activas del target.
    const { error: signOutErr } = await admin.auth.admin.signOut(
      body.cobrador_id,
      "global",
    );
    if (signOutErr) {
      // No bloqueamos — la password ya cambió.
      console.error(
        "forzar-password: global signOut failed",
        signOutErr,
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Contraseña actualizada",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // Errores no anticipados (parseo JSON inválido, network, etc.).
    console.error("forzar-password: unhandled error", e);
    return jsonError("Error interno", 500);
  }
});
