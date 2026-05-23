// Edge Function: cambiar-email-cobrador
//
// Permite al super_admin cambiar el email de un miembro de cualquier
// tenant. Útil cuando alguien cambia de empresa, hace typo al invitar,
// o el dominio del email cambia.
//
// Comportamiento:
//   - Llama auth.admin.updateUserById con email_confirm:true para que
//     el nuevo email quede confirmado de una sin re-verificación.
//   - El super_admin es responsable de notificar al usuario por canal
//     fuera-de-banda (la app no manda email de notificación al viejo).
//
// Guards:
//   - Sólo super_admin.
//   - No se modifica a sí mismo.
//   - No se modifica a otro super_admin.
//   - Sólo a usuarios con email_confirmed_at != null (confirmados); para
//     pending invites el flujo correcto es 'Reenviar invitación' con el
//     email corregido.
//   - El nuevo email tiene que pasar validación regex básica.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";

interface CambiarEmailRequest {
  cobrador_id: string;
  nuevo_email: string;
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

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede cambiar emails", 403);
    }

    const body: CambiarEmailRequest = await req.json();
    if (!body.cobrador_id || !body.nuevo_email) {
      return jsonError(
        "cobrador_id y nuevo_email son requeridos",
        400,
      );
    }

    // Normalizar: Supabase guarda emails en lowercase, así la idempotencia
    // y comparaciones quedan consistentes. Trim por si el cliente mandó
    // espacios extra.
    const nuevoEmail = body.nuevo_email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(nuevoEmail)) {
      return jsonError("Email inválido", 400);
    }

    if (body.cobrador_id === user.id) {
      return jsonError(
        "No podés cambiar tu propio email desde acá",
        400,
      );
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Lookup del target — necesitamos saber el email actual + tenant para
    // el audit + verificar que no sea pending ni super_admin.
    const { data: targetUserData, error: targetErr } = await admin.auth.admin
      .getUserById(body.cobrador_id);
    if (targetErr) {
      console.error("cambiar-email: getUserById falló", targetErr);
      return jsonError("Error interno", 500);
    }
    const targetUser = targetUserData?.user;
    if (!targetUser) return jsonError("Usuario no existe", 404);

    if (!targetUser.email_confirmed_at) {
      return jsonError(
        "El usuario no aceptó la invitación. Usá 'Reenviar invitación' " +
          "con el email correcto en vez de cambiarlo acá.",
        400,
      );
    }

    const emailAnterior = targetUser.email;
    if ((emailAnterior ?? "").toLowerCase() === nuevoEmail) {
      // Idempotencia: si ya tiene ese email (comparado case-insensitive
      // porque Supabase guarda en lowercase), no hacemos nada.
      return new Response(
        JSON.stringify({
          ok: true,
          message: "El email ya era el mismo",
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("cambiar-email: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError(
        "No se puede modificar el email de otro super_admin",
        400,
      );
    }

    // Pre-flight: chequear que el nuevo email no esté ya tomado por
    // OTRO usuario distinto al target. Sin este check, el update
    // fallaba con el error humanizado pero el intent row del audit_log
    // ya quedaba escrito → pollution del timeline con intents fallidos.
    // Mismo patrón que crear-tenant e invitar-cobrador.
    //
    // TODO escalado: listUsers con perPage:1000 cubre hasta 1000
    // users totales. Cuando crezca, migrar a un RPC SECURITY DEFINER.
    const { data: existingUsers, error: lookupErr } = await admin
      .auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (lookupErr) {
      console.error("cambiar-email: listUsers falló", lookupErr);
      return jsonError("Error interno", 500);
    }
    // Filtramos excluyendo al target — su email actual es distinto al
    // nuevo (pasamos el check de idempotencia arriba) así que si
    // aparece en la lista con el email nuevo, es OTRO usuario.
    const yaTomado = (existingUsers?.users ?? []).some(
      (u) =>
        (u.email ?? "").toLowerCase() === nuevoEmail &&
        u.id !== body.cobrador_id,
    );
    if (yaTomado) {
      return jsonError(
        "Ese email ya está registrado en otro usuario. Elegí otro o, " +
          "si es del mismo usuario, contactá soporte.",
        400,
      );
    }

    // Intent/success split. Ver justificación en forzar-password-cobrador.
    //
    // Para email, el intent row usa valor_nuevo Map con action y
    // 'intent' (el email destino) para que el timeline distinga del
    // success row (que usa strings y dispara el path "genérico" del
    // _resumenCambio que muestra "email: viejo → nuevo").
    //
    // valor_anterior/valor_nuevo contienen los emails — son PII pero
    // queda en el audit que sólo super_admin lee.
    const { error: intentErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "email",
      valor_anterior: emailAnterior,
      valor_nuevo: { action: "email_change_intent", intent: nuevoEmail },
      user_id: user.id,
      user_rol: "super_admin",
    });
    if (intentErr) {
      console.error("cambiar-email: intent audit insert falló", intentErr);
      return jsonError(
        "No se pudo registrar la auditoría — el cambio no se aplicó. " +
          "Reintentá en unos segundos.",
        500,
      );
    }

    // Actualizar email + mantener confirmado (no re-verificación).
    const { error: updErr } = await admin.auth.admin.updateUserById(
      body.cobrador_id,
      { email: nuevoEmail, email_confirm: true },
    );
    if (updErr) {
      // El intent row queda como evidencia del intento fallido.
      console.error(
        "cambiar-email: updateUserById falló DESPUÉS del intent audit. " +
          `cobrador_id=${body.cobrador_id}. Timeline mostrará solo el intent.`,
        updErr,
      );
      return jsonError(humanizeAuthError(updErr.message), 400);
    }

    // Cambio aplicado — registramos el success con valores strings
    // (no Map) para que _resumenCambio del timeline muestre el formato
    // genérico "email: viejo → nuevo".
    const { error: successErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "email",
      valor_anterior: emailAnterior,
      valor_nuevo: nuevoEmail,
      user_id: user.id,
      user_rol: "super_admin",
    });
    if (successErr) {
      // Email ya cambió pero success audit perdido. Log loud.
      console.error(
        "cambiar-email: success audit insert FALLÓ — email sí cambió, " +
          `intent row está, success row NO. cobrador_id=${body.cobrador_id}`,
        successErr,
      );
    }

    // Invalidar todas las sesiones del target — sino sigue logueado con
    // JWT del email viejo hasta el siguiente refresh (~1h). Para un cambio
    // de identidad mejor forzamos re-login en todos los devices.
    const { error: signOutErr } = await admin.auth.admin.signOut(
      body.cobrador_id,
      "global",
    );
    if (signOutErr) {
      // No bloqueamos — el email ya cambió.
      console.error("cambiar-email: signOut global falló", signOutErr);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Email actualizado",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // Scrub por consistencia con crear-tenant / reenviar-invitacion /
    // invitar-cobrador. Acá no hay password generada en scope, pero
    // `nuevoEmail` (PII) sí, y los logs del Dashboard son consultables.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("cambiar-email-cobrador: unhandled", safeMessage);
    return jsonError("Error interno", 500);
  }
});
