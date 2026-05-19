// Edge Function: crear-tenant
//
// Crea un tenant completo en un solo click desde el panel super_admin:
//   1. Inserta el row en `tenants` (el trigger habilita los módulos base).
//   2. Habilita módulos no-base extra vía set_tenant_modulo RPC.
//   3. Invita al admin por email (Supabase Auth → email de invitación).
//
// Si el invite falla tras crear el tenant, hace rollback (delete cascade
// limpia tenant_modulos). Si el rollback también falla (raro), devuelve
// el `orphan_tenant_id` para que el super_admin lo limpie manualmente.
//
// Despliegue:
//   supabase functions deploy crear-tenant
//   (o pegando este archivo en Supabase Dashboard → Edge Functions)
//
// Variables esperadas (configuradas automáticamente por Supabase):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Body esperado (JSON):
//   {
//     "tenant_nombre": "ISP Las Lomas",
//     "admin_email": "marcos@laslomas.ni",
//     "admin_nombre": "Marcos Pineda",
//     "admin_telefono": "+50588881234",      // opcional
//     "modulos_extra": ["inventario"],        // opcional, sólo no-base
//     "redirect_to": "https://app.../?flow=invite"   // opcional
//   }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface CrearTenantRequest {
  tenant_nombre: string;
  admin_email: string;
  admin_nombre: string;
  admin_telefono?: string;
  modulos_extra?: string[];
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

    // callerClient = JWT del super_admin → atraviesa RLS y deja el audit
    // trail correcto (habilitado_por = super_admin en tenant_modulos).
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar caller es super_admin.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede crear tenants", 403);
    }

    // Validar body.
    const body: CrearTenantRequest = await req.json();
    const nombre = (body.tenant_nombre ?? "").trim();
    const email = (body.admin_email ?? "").trim().toLowerCase();
    const adminNombre = (body.admin_nombre ?? "").trim();
    const adminTelefono = body.admin_telefono?.trim() || null;
    const modulosExtra = Array.isArray(body.modulos_extra)
      ? body.modulos_extra
      : [];

    if (!nombre) return jsonError("tenant_nombre es requerido", 400);
    if (nombre.length > 120) {
      return jsonError("tenant_nombre demasiado largo (max 120)", 400);
    }
    // 'System' es el nombre del tenant interno (UUID 00000000-...) que
    // aloja a los super_admin. Permitir crear otro "System" confundiría
    // la lista — bloqueamos case-insensitive.
    if (nombre.toLowerCase() === "system") {
      return jsonError(
        '"System" es un nombre reservado, usá otro',
        400,
      );
    }
    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return jsonError("admin_email inválido", 400);
    }
    if (!adminNombre) return jsonError("admin_nombre es requerido", 400);

    // service_role: sólo para el invite (auth.admin) y rollback. Las
    // operaciones de DB van vía callerClient para que la RLS valide.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Pre-flight: validar que los módulos extra existen y no son base.
    // (Base se habilita auto por trigger; pasarlos en "extra" sería
    // un no-op confuso.) También evita un rollback caro si alguien
    // tipea mal el código del módulo.
    if (modulosExtra.length > 0) {
      const { data: modRows, error: modErr } = await admin
        .from("modulos")
        .select("codigo, es_base")
        .in("codigo", modulosExtra);
      if (modErr) {
        return jsonError(`Error validando módulos: ${modErr.message}`, 500);
      }
      const encontrados = new Set((modRows ?? []).map((m) => m.codigo));
      const faltantes = modulosExtra.filter((m) => !encontrados.has(m));
      if (faltantes.length > 0) {
        return jsonError(
          `Módulos inexistentes: ${faltantes.join(", ")}`,
          400,
        );
      }
      const baseEnExtra = (modRows ?? [])
        .filter((m) => m.es_base)
        .map((m) => m.codigo);
      if (baseEnExtra.length > 0) {
        return jsonError(
          `Módulos base no van en modulos_extra (ya se habilitan ` +
            `automáticamente): ${baseEnExtra.join(", ")}`,
          400,
        );
      }
    }

    // 1. Crear el tenant. RLS `super_admin_all` lo permite vía callerClient.
    //    El trigger `trg_tenants_habilitar_modulos_base` habilita cobranza.
    const { data: nuevoTenant, error: tErr } = await callerClient
      .from("tenants")
      .insert({ nombre })
      .select("id")
      .single();
    if (tErr || !nuevoTenant) {
      return jsonError(`Error creando tenant: ${tErr?.message}`, 500);
    }
    const tenantId: string = nuevoTenant.id;

    // Guard contra accidente cósmico: el insert NO debería retornar el
    // System tenant, pero si por algún motivo se devolviera, abortamos.
    if (tenantId === SYSTEM_TENANT) {
      return jsonError("Conflicto: el tenant creado es System", 500);
    }

    // 2. Habilitar módulos extra. Usamos la RPC para mantener el audit
    //    trail (`habilitado_por = super_admin`). Si uno falla, rollback.
    for (const modulo of modulosExtra) {
      const { error: setErr } = await callerClient.rpc("set_tenant_modulo", {
        p_tenant_id: tenantId,
        p_modulo: modulo,
        p_habilitado: true,
      });
      if (setErr) {
        await rollbackTenant(admin, tenantId);
        return jsonError(
          `Error habilitando módulo ${modulo}: ${setErr.message}`,
          500,
        );
      }
    }

    // 3. Invitar al admin. La metadata se la come el trigger
    //    handle_new_user al confirmar la invitación → crea la fila en
    //    cobradores con rol=admin + tenant_id correcto.
    const { data: invite, error: invErr } = await admin.auth.admin
      .inviteUserByEmail(email, {
        data: {
          tenant_id: tenantId,
          rol: "admin",
          nombre: adminNombre,
          telefono: adminTelefono,
        },
        redirectTo: body.redirect_to,
      });

    if (invErr || !invite?.user) {
      // Rollback: borramos el tenant — cascade limpia tenant_modulos.
      const rollbackOk = await rollbackTenant(admin, tenantId);
      const rawMsg = invErr?.message ?? "No se creó el usuario";
      const msg = humanizeAuthError(rawMsg);
      if (!rollbackOk) {
        // Cleanup falló — devolvemos el orphan id para limpieza manual.
        return new Response(
          JSON.stringify({
            ok: false,
            error: `Invite falló (${msg}) y el rollback también. ` +
              `Borrá manualmente el tenant ${tenantId}.`,
            orphan_tenant_id: tenantId,
          }),
          {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 500,
          },
        );
      }
      return jsonError(`Invite falló: ${msg}`, 400);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        tenant_id: tenantId,
        admin_user_id: invite.user.id,
        message: "Tenant creado e invitación enviada por email",
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

async function rollbackTenant(
  admin: ReturnType<typeof createClient>,
  tenantId: string,
): Promise<boolean> {
  // service_role evita el "no tengo permiso" si el caller llegó a este
  // punto pero su sesión expiró entre el insert y el rollback. Cascade
  // cubre tenant_modulos / settings / etc.
  const { error } = await admin.from("tenants").delete().eq("id", tenantId);
  return !error;
}

/// Mapea los errores conocidos de Supabase Auth (en inglés) a copy en
/// español que coincide con el resto del panel. Fallback al string
/// original para que un mensaje desconocido no quede mudo.
function humanizeAuthError(raw: string): string {
  const lower = raw.toLowerCase();
  // Regex tolera variantes de wording: "already registered", "already
  // been registered", "already exists". Substring strict fallaba sobre
  // el mensaje real de Supabase ("...has already been registered").
  if (
    /already.*(registered|exists)/.test(lower) ||
    lower.includes("user already")
  ) {
    return "Ya existe un usuario con ese email — usá otro o, " +
      "si querés moverlo de tenant, contactá soporte.";
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
