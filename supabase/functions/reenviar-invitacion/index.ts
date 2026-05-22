// Edge Function: reenviar-invitacion
//
// Re-envía la invitación a un usuario que aún no completó el signup
// (email_confirmed_at IS NULL). El link original puede haber expirado
// o haberse perdido en spam.
//
// Implementación pragmática: borra el usuario y lo re-crea con la
// misma metadata. Para pending invites es seguro — la row de cobradores
// cascadea por la FK, no hay clientes asignados aún, no hay pagos /
// recibos huérfanos. La fila se recrea limpia al re-aceptar.
//
// Dos modos según `enviar_email`:
//   - true (default) → inviteUserByEmail (manda email nuevo).
//   - false          → createUser con password aleatoria + email_confirm=true
//                      (no manda nada; devuelve nueva_password para que
//                      el caller la comparta por otro canal). Útil
//                      cuando SMTP está en sandbox y el destinatario
//                      no recibe email automatizado.
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
  // Si false: createUser con password aleatoria, devuelve nueva_password.
  // Default true: inviteUserByEmail con el redirect_to del caller.
  enviar_email?: boolean;
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
    // poder reportar al super_admin si la re-creación falla después del
    // delete y debe recrearse manualmente.
    const snapshot = {
      email: targetEmail,
      tenant_id: tc.tenant_id,
      rol: tc.rol,
      nombre: tc.nombre,
      telefono: tc.telefono ?? null,
      prefijo_recibo: tc.rol === "cobrador" ? (tc.prefijo_recibo ?? null) : null,
    };

    // Persistir el snapshot al audit_log ANTES del delete. Antes
    // sólo iba a console.error; los logs rotan a los pocos días y si
    // la re-creación falla y nadie atiende a tiempo, perdemos toda la
    // info para reconstruir el invite manualmente. En audit_log queda
    // para siempre y el super_admin lo ve en el timeline del miembro.
    const { error: snapAuditErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "invitacion",
      valor_anterior: snapshot,
      valor_nuevo: { action: "snapshot_before_resend" },
      user_id: user.id,
      user_rol: yo.rol,
    });
    if (snapAuditErr) {
      // Si no podemos auditar el snapshot, no destruimos el user. Mejor
      // dejar el pending invite intacto que borrarlo sin recovery info.
      console.error("reenviar: snapshot audit insert falló", snapAuditErr);
      return jsonError(
        "No se pudo registrar la auditoría previa al reenvío — la " +
          "invitación NO se tocó. Reintentá en unos segundos.",
        500,
      );
    }

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

    // Re-crear el user con la misma metadata, mismo email. Dos paths:
    //   - enviarEmail=true → inviteUserByEmail (Supabase manda email
    //     con magic-link al user).
    //   - enviarEmail=false → createUser con password aleatoria +
    //     email_confirm=true (no manda nada; devolvemos la password
    //     en nueva_password para que el caller la comparta por otro
    //     canal). Mismo patrón que crear-tenant.
    //
    // ATENCIÓN: si la re-creación falla, el user quedó borrado sin
    // reemplazo. Logueamos el snapshot loud para recovery manual.
    const enviarEmail = body.enviar_email !== false;
    const metadata = {
      tenant_id: snapshot.tenant_id,
      rol: snapshot.rol,
      nombre: snapshot.nombre,
      telefono: snapshot.telefono,
      prefijo_recibo: snapshot.prefijo_recibo,
    };

    let invErr: { message: string } | null = null;
    let newUserId: string | null = null;
    let nuevaPassword: string | null = null;

    if (enviarEmail) {
      const { data: invite, error } = await admin.auth.admin
        .inviteUserByEmail(targetEmail, {
          data: metadata,
          redirectTo: body.redirect_to,
        });
      if (error) {
        invErr = error;
      } else if (!invite.user) {
        invErr = { message: "invite sin user" };
      } else {
        newUserId = invite.user.id;
      }
    } else {
      const generated = generarPasswordSegura();
      const { data: created, error } = await admin.auth.admin.createUser({
        email: targetEmail,
        password: generated,
        user_metadata: metadata,
        email_confirm: true,
      });
      if (error) {
        invErr = error;
      } else if (!created?.user) {
        invErr = { message: "createUser sin user" };
      } else {
        newUserId = created.user.id;
        nuevaPassword = generated;
      }
    }

    if (invErr !== null || newUserId === null) {
      const rawMsg = invErr?.message ?? "error desconocido";
      const msg = humanizeAuthError(rawMsg);
      console.error(
        "reenviar: re-creación falló DESPUÉS de delete — recovery manual " +
          "requerida con este snapshot:",
        JSON.stringify(snapshot),
        invErr,
      );
      return jsonError(
        "El usuario fue eliminado pero la re-creación falló. Recreá la " +
          "invitación manualmente desde 'Invitar' con email=" +
          `${snapshot.email} y rol=${snapshot.rol}. Detalle: ${msg}`,
        500,
      );
    }

    // Audit log: registrar el reenvío. valor_anterior tiene el id
    // viejo (ahora borrado) + el snapshot del cobrador antes del
    // delete (incluido inline para que el row sea visible en el
    // timeline del miembro nuevo — la row "snapshot_before_resend"
    // anterior usa registro_id=old y queda invisible al filtrar
    // por el nuevo user_id). valor_nuevo tiene el id del nuevo user
    // y el canal usado (email vs link generado server-side).
    const { error: auditErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: newUserId,
      campo: "invitacion",
      valor_anterior: {
        id: body.cobrador_id,
        action: "previous_invite",
        snapshot: snapshot,
      },
      valor_nuevo: {
        id: newUserId,
        action: enviarEmail
          ? "resent_invitation"
          : "regenerated_credentials",
      },
      user_id: user.id,
      user_rol: yo.rol,
    });
    if (auditErr) {
      console.error("reenviar: audit insert falló", auditErr);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: enviarEmail
          ? "Invitación reenviada por email"
          : "Credenciales generadas — compartilas con el usuario",
        new_user_id: newUserId,
        // Eco del email + password nueva sólo cuando enviar_email=false.
        // Para el flow email queda null (no exponer en logs ni en
        // history del browser).
        email: targetEmail,
        nueva_password: nuevaPassword,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente: si el throw ocurrió tras
    // generar la password aleatoria (modo no-email), ésta podría
    // aparecer en el stack trace según cómo Deno formatee la
    // excepción. Loggeamos en server y devolvemos mensaje genérico.
    //
    // Importante: scrub del Error completo a solo e.message — la
    // password generada está en scope al momento del throw. Si el SDK
    // alguna vez incluyera el request body en el Error (vía `cause`),
    // `e` completo podría contener la password — los logs del
    // Dashboard son consultables por cualquier colaborador del
    // proyecto. Mismo patrón que invitar-cobrador y crear-tenant.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("reenviar-invitacion: unhandled error", safeMessage);
    return jsonError("Error interno — revisá los logs de la función", 500);
  }
});

/// Mapea los errores conocidos de Supabase Auth (en inglés) a copy en
/// español. Mismo patrón que crear-tenant y invitar-cobrador.
function humanizeAuthError(raw: string): string {
  const lower = raw.toLowerCase();
  if (
    /already.*(registered|exists)/.test(lower) ||
    lower.includes("user already")
  ) {
    return "Ya existe un usuario con ese email — usá otro o, " +
      "si querés moverlo de tenant, contactá soporte.";
  }
  if (lower.includes("sending invite") || lower.includes("sending email")) {
    return "El proveedor de email rechazó el envío. Si estás usando " +
      "Resend en sandbox, solo podés invitar al email dueño de tu " +
      "cuenta Resend — para invitar a otros, verificá tu dominio.";
  }
  if (lower.includes("rate limit")) {
    return "Rate limit del proveedor de email alcanzado — esperá un " +
      "rato y reintentá.";
  }
  if (lower.includes("invalid email")) {
    return "Email inválido según el proveedor de email.";
  }
  return raw;
}

function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ ok: false, error: message }),
    {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status,
    },
  );
}

/// Genera una password aleatoria de 16 chars usando crypto.getRandomValues.
///
/// NOTA: Esta función está duplicada en crear-tenant y reenviar-invitacion
/// porque el Dashboard de Supabase deploya un único archivo por función
/// — no soporta importar `../_shared/...` cuando subís el código vía
/// paste. Si en el futuro se migra a Supabase CLI (`supabase functions
/// deploy`), mover esta función a `supabase/functions/_shared/passwords.ts`
/// y reemplazar ambos cuerpos por un import. Sincronizar el alphabet con
/// _ForzarPasswordDialog del cliente.
function generarPasswordSegura(): string {
  const chars =
    "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 16; i++) {
    // Sesgo del módulo: 256 mod 63 = 4, así que 4 buckets reciben 5
    // muestras vs 4 — pérdida total ~0.4 bits sobre 16 chars
    // (95.27 vs 95.64 bits). Irrelevante para una password rotable.
    out += chars[bytes[i] % chars.length];
  }
  return out;
}
