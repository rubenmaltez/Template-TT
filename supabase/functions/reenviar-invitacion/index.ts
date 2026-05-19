// Edge Function: reenviar-invitacion
//
// Re-envía el email de invitación a un usuario que aún no completó el
// signup (email_confirmed_at IS NULL). El link original puede haber
// expirado o haberse perdido en spam.
//
// Implementación pragmática: borra el usuario y lo re-invita con la
// misma metadata. Para pending invites es seguro — la row de cobradores
// cascadea por la FK, no hay clientes asignados aún, no hay pagos /
// recibos huérfanos. La fila se recrea limpia al re-aceptar.
//
// Guards:
//   - Sólo super_admin o admin (rol en cobradores).
//   - Admin sólo puede reenviar a usuarios de SU mismo tenant.
//   - El target debe estar en pending (email_confirmed_at IS NULL); si
//     ya aceptó, devolvemos error y se sugiere 'Reset password vía email'.
//   - super_admin no puede reenviar invitaciones a otros super_admin.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface ReenviarRequest {
  cobrador_id: string;
  redirect_to?: string;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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

    // Verificar caller en cobradores.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("tenant_id, rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }

    const callerEsSuperAdmin = yo.rol === "super_admin";
    const callerEsAdmin = yo.rol === "admin";
    if (!callerEsSuperAdmin && !callerEsAdmin) {
      return jsonError(
        "Sólo admin o super_admin puede reenviar invitaciones",
        403,
      );
    }

    const body: ReenviarRequest = await req.json();
    if (!body.cobrador_id) {
      return jsonError("cobrador_id requerido", 400);
    }

    // Cliente service_role para inspeccionar auth.users y borrar/invitar.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Obtener el target user (auth.users).
    const { data: targetUserData, error: targetErr } = await admin.auth.admin
      .getUserById(body.cobrador_id);
    if (targetErr) {
      console.error("reenviar: getUserById falló", targetErr);
      return jsonError("Error interno", 500);
    }
    const targetUser = targetUserData?.user;
    if (!targetUser) return jsonError("Usuario no existe", 404);

    if (targetUser.email_confirmed_at) {
      return jsonError(
        "El usuario ya aceptó la invitación. Usá 'Reset password vía email' " +
          "si tiene problemas con su contraseña.",
        400,
      );
    }

    const targetEmail = targetUser.email;
    if (!targetEmail) return jsonError("Usuario sin email", 400);

    // Obtener metadata del cobrador (rol, tenant, prefijo, etc.).
    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol, nombre, telefono, prefijo_recibo")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("reenviar: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError(
        "No se puede reenviar invitación a otro super_admin",
        400,
      );
    }

    // Admin sólo puede operar dentro de su tenant.
    if (callerEsAdmin && tc.tenant_id !== yo.tenant_id) {
      return jsonError(
        "Sólo podés reenviar invitaciones de tu propio tenant",
        403,
      );
    }

    // Snapshot de la data del cobrador antes de borrar — necesario para
    // poder reportar al super_admin si el invite falla después del delete
    // y debe recrearse manualmente.
    const snapshot = {
      email: targetEmail,
      tenant_id: tc.tenant_id,
      rol: tc.rol,
      nombre: tc.nombre,
      telefono: tc.telefono ?? null,
      prefijo_recibo: tc.rol === "cobrador" ? (tc.prefijo_recibo ?? null) : null,
    };

    // Borrar el user (cascadea cobradores). Para pending invites esto es
    // seguro porque no hay datos operativos asociados.
    const { error: delErr } = await admin.auth.admin.deleteUser(
      body.cobrador_id,
    );
    if (delErr) {
      // status undefined cuando no hay error real; los 404 (race con otra
      // tab que ya borró) los tratamos como already-done.
      const status = (delErr as { status?: number }).status;
      if (status === 404) {
        return jsonError(
          "Otro super_admin ya reenvió esta invitación (refresca la lista)",
          409,
        );
      }
      console.error("reenviar: deleteUser falló", delErr);
      return jsonError("Error eliminando el usuario previo", 500);
    }

    // Re-invitar con la misma metadata, mismo email.
    // ATENCIÓN: si esta call falla, el usuario quedó borrado sin
    // reemplazo. Logueamos el snapshot loud para que el super_admin pueda
    // recrear manualmente desde Authentication o ejecutar la invitación
    // a mano.
    const { data: invite, error: invErr } = await admin.auth.admin
      .inviteUserByEmail(targetEmail, {
        data: {
          tenant_id: snapshot.tenant_id,
          rol: snapshot.rol,
          nombre: snapshot.nombre,
          telefono: snapshot.telefono,
          prefijo_recibo: snapshot.prefijo_recibo,
        },
        redirectTo: body.redirect_to,
      });

    if (invErr) {
      console.error(
        "reenviar: invite falló DESPUÉS de delete — recovery manual " +
          "requerida con este snapshot:",
        JSON.stringify(snapshot),
        invErr,
      );
      return jsonError(
        "El usuario fue eliminado pero el reinvite falló. Recreá la " +
          "invitación manualmente desde 'Invitar' con email=" +
          `${snapshot.email} y rol=${snapshot.rol}. Detalle: ${invErr.message}`,
        500,
      );
    }
    if (!invite.user) {
      console.error("reenviar: invite sin user, snapshot:", snapshot);
      return jsonError(
        "El usuario fue eliminado pero no se recreó. Recreá la invitación " +
          "manualmente con email=" + snapshot.email,
        500,
      );
    }

    // Audit log: registrar el reenvío. valor_anterior tiene el id viejo
    // (ahora borrado), valor_nuevo el id del re-invite.
    const { error: auditErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: invite.user.id,
      campo: "invitacion",
      valor_anterior: { id: body.cobrador_id, action: "previous_invite" },
      valor_nuevo: { id: invite.user.id, action: "resent_invitation" },
      user_id: user.id,
      user_rol: yo.rol,
    });
    if (auditErr) {
      console.error("reenviar: audit insert falló", auditErr);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Invitación reenviada",
        new_user_id: invite.user.id,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    console.error("reenviar-invitacion: unhandled error", e);
    return jsonError("Error interno", 500);
  }
});

function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ ok: false, error: message }),
    {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status,
    },
  );
}
