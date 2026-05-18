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

    // Validar body.
    const body: InvitarRequest = await req.json();
    if (!body.email || !body.nombre || !body.rol) {
      return jsonError("email, nombre y rol son requeridos", 400);
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
    const { data: invite, error: invErr } = await admin.auth.admin
      .inviteUserByEmail(body.email, {
        data: {
          tenant_id: targetTenantId,
          rol: body.rol,
          nombre: body.nombre,
          telefono: body.telefono ?? null,
          prefijo_recibo: body.rol === "cobrador"
            ? (body.prefijo_recibo ?? null)
            : null,
        },
      });

    if (invErr) return jsonError(`Auth: ${invErr.message}`, 400);
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
    return jsonError(`Error: ${String(e)}`, 500);
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
