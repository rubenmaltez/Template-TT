// Edge Function: invitar-cobrador
//
// Permite invitar usuarios al sistema:
//   - rol='admin'        → invita dentro de SU PROPIO tenant. Cualquier
//                          `tenant_id` que venga en el body se ignora
//                          (defensa contra privilege escalation).
//   - rol='super_admin'  → invita a CUALQUIER tenant; debe pasar
//                          `tenant_id` en el body. No puede invitar al
//                          tenant System.
//
// Cuando el invitado abre el email y crea su contraseña, el trigger
// `handle_new_user` (migración 0024) crea su fila en `cobradores` con el
// metadata que pasamos acá (tenant_id, rol, nombre, etc.).
//
// Despliegue:
//   supabase functions deploy invitar-cobrador
//   (o pegando este archivo en Supabase Dashboard → Edge Functions)
//
// Variables esperadas (configuradas automáticamente por Supabase):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Body esperado (JSON):
//   {
//     "email": "user@empresa.com",
//     "nombre": "Pedro Pérez",
//     "rol": "admin" | "admin_cobranza" | "cobrador",
//     "telefono": "+50588000000",     // opcional
//     "prefijo_recibo": "COB-01",     // opcional, solo para rol cobrador
//     "tenant_id": "<uuid>"           // REQUERIDO sólo si caller es super_admin
//   }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface InvitarRequest {
  email: string;
  nombre: string;
  rol: "admin" | "admin_cobranza" | "cobrador";
  telefono?: string;
  prefijo_recibo?: string;
  tenant_id?: string;
  // Origen del cliente para que Supabase redirija al usuario tras
  // verificar el invite. Debe incluir `?flow=invite` o equivalente
  // para que la app pueda routear a /set-password (ver auth_flow_provider).
  redirect_to?: string;
}

const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

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

    // Cliente con el JWT del caller — para identificar quién está invitando.
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
        "Sólo admin o super_admin puede invitar usuarios",
        403,
      );
    }

    // Validar body. Rechazamos chars de control C0 (\x00-\x1F) y C1 (\x7F-\x9F) para evitar inputs que rompen jsonb o text en
    // Postgres con errores opacos. Telefono también trimmed para que
    // "   " (espacios) no pase el length check.
    const body: InvitarRequest = await req.json();
    const email = (body.email ?? "").trim().toLowerCase();
    const nombre = (body.nombre ?? "").trim();
    const telefono = (body.telefono ?? "").trim();
    const CONTROL = /[\x00-\x1F\x7F-\x9F]/;

    if (!email || !nombre || !body.rol) {
      return jsonError("email, nombre y rol son requeridos", 400);
    }
    if (CONTROL.test(email) || CONTROL.test(nombre) || CONTROL.test(telefono)) {
      return jsonError("Los campos no pueden contener caracteres de control", 400);
    }
    // Email regex: mismo patrón que crear-tenant para consistencia.
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return jsonError("email inválido", 400);
    }
    if (nombre.length > 120) {
      return jsonError("nombre demasiado largo (max 120)", 400);
    }
    if (telefono.length > 32) {
      return jsonError("telefono demasiado largo (max 32)", 400);
    }
    if (!["admin", "admin_cobranza", "cobrador"].includes(body.rol)) {
      return jsonError("Rol inválido", 400);
    }
    if (
      body.prefijo_recibo &&
      !/^[A-Z0-9-]{2,16}$/.test(body.prefijo_recibo)
    ) {
      return jsonError("Prefijo debe ser [A-Z0-9-]{2,16}", 400);
    }

    // Cliente con service_role para verificar tenants e invitar (auth.admin).
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Resolver el tenant_id objetivo según el rol del caller.
    let targetTenantId: string;
    if (callerEsAdmin) {
      // Admin sólo invita dentro de su propio tenant. Cualquier
      // tenant_id del body se descarta a propósito.
      targetTenantId = yo.tenant_id;
    } else {
      // super_admin: tenant_id obligatorio, no puede ser System, debe existir.
      if (!body.tenant_id) {
        return jsonError(
          "super_admin debe pasar tenant_id en el body",
          400,
        );
      }
      if (body.tenant_id === SYSTEM_TENANT) {
        return jsonError(
          "No se puede invitar al tenant System",
          400,
        );
      }
      const { data: tenantRow, error: tenantErr } = await admin
        .from("tenants")
        .select("id")
        .eq("id", body.tenant_id)
        .maybeSingle();
      if (tenantErr) {
        return jsonError(
          `Error verificando tenant: ${tenantErr.message}`,
          500,
        );
      }
      if (!tenantRow) return jsonError("Tenant no existe", 404);
      targetTenantId = body.tenant_id;
    }

    // Invitar: manda email + crea auth.users row. El trigger
    // handle_new_user creará la fila en `cobradores` con este metadata.
    // redirect_to: si lo manda el cliente, lo respetamos (debería tener
    //   `?flow=invite` para que el app route a /set-password). Si no,
    //   Supabase usa el Site URL configurado.
    const { data: invite, error: invErr } = await admin.auth.admin
      .inviteUserByEmail(email, {
        data: {
          tenant_id: targetTenantId,
          rol: body.rol,
          nombre: nombre,
          telefono: telefono === "" ? null : telefono,
          prefijo_recibo: body.rol === "cobrador"
            ? (body.prefijo_recibo ?? null)
            : null,
        },
        redirectTo: body.redirect_to,
      });

    if (invErr) {
      return jsonError(humanizeAuthError(invErr.message), 400);
    }
    if (!invite.user) return jsonError("No se creó el usuario", 500);

    return new Response(
      JSON.stringify({
        ok: true,
        user_id: invite.user.id,
        tenant_id: targetTenantId,
        message: "Invitación enviada por email",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente — puede leakear stack o data
    // sensible. Loggeamos server-side y devolvemos mensaje genérico.
    console.error("invitar-cobrador unhandled error:", e);
    return jsonError("Error interno — revisá los logs de la función", 500);
  }
});

/// Mapea los errores conocidos de Supabase Auth (en inglés) a copy en
/// español. Mismo patrón que crear-tenant y reenviar-invitacion.
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
