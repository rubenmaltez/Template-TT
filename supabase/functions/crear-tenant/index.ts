// Edge Function: crear-tenant
//
// Crea un tenant completo en un solo click desde el panel super_admin:
//   1. Inserta el row en `tenants` (el trigger habilita los módulos base).
//   2. Habilita módulos no-base extra vía set_tenant_modulo RPC.
//   3. Crea al admin con metadata. Dos modos según enviar_email:
//      - true  → inviteUserByEmail (manda email automático).
//      - false → generateLink({type:'invite'}) — crea el user y
//                devuelve invite_link para que el super_admin lo
//                pase por otro canal (workaround SMTP sandbox).
//
// Si algo falla tras crear el tenant, hace rollback completo:
//   - Borra el user de auth.users (cascade limpia cobradores).
//   - Borra el tenant (cascade limpia tenant_modulos / settings).
// Si el rollback también falla, devuelve `orphan_tenant_id` para que
// el super_admin lo limpie manualmente.
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
//     "redirect_to": "https://app.../?flow=invite",  // opcional
//     "enviar_email": true                    // opcional, default true
//   }
//
// Respuesta éxito:
//   { ok: true, tenant_id, admin_user_id, invite_link?, message }
//   invite_link sólo viene cuando enviar_email=false.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface CrearTenantRequest {
  tenant_nombre: string;
  admin_email: string;
  admin_nombre: string;
  admin_telefono?: string;
  modulos_extra?: string[];
  redirect_to?: string;
  // Si false, no manda email — usa generateLink y devuelve invite_link
  // para que el super_admin lo copie y pase por otro canal. Útil para
  // Resend en sandbox o cuando el destinatario no puede recibir el
  // email automatizado.
  enviar_email?: boolean;
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
    // Default true: el caller tiene que pedir explícitamente "no email"
    // para activar el flow de generateLink. Falsey check tolera null/undefined.
    const enviarEmail = body.enviar_email !== false;

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

    // Pre-flight: chequear que el email no exista en auth.users.
    // `inviteUserByEmail` ya falla nativamente si existe — pero
    // `generateLink({type:'invite'})` NO falla: silenciosamente
    // genera un magic-link para el usuario existente. Eso permitiría:
    // sembrar el email de un admin de otro tenant, generar el link,
    // y al loguearse el existente, su row en cobradores se vería
    // sobrescrita con el tenant nuevo (ON CONFLICT UPDATE) —
    // perdiendo su rol original. Bloquear acá nivela ambos paths.
    //
    // TODO escalado: listUsers con perPage:1000 cubre hasta 1000
    // users totales en el sistema. Cuando crezca, migrar a un RPC
    // SECURITY DEFINER que consulte `auth.users` con un WHERE email=…
    // (auth.users no está expuesto vía PostgREST).
    const { data: existingUsers, error: lookupErr } = await admin
      .auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (lookupErr) {
      return jsonError(
        `No pude verificar el email: ${lookupErr.message}`,
        500,
      );
    }
    const yaExiste = (existingUsers?.users ?? []).some(
      (u) => (u.email ?? "").toLowerCase() === email,
    );
    if (yaExiste) {
      return jsonError(
        "Ya existe un usuario con ese email — usá otro o, " +
          "si querés moverlo de tenant, contactá soporte.",
        400,
      );
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

    // 3. Crear el user con metadata. Dos paths:
    //    a) enviarEmail=true → inviteUserByEmail (manda email).
    //    b) enviarEmail=false → generateLink({type:'invite'}) (sólo
    //       crea el user y devuelve action_link para que el super_admin
    //       lo pase por otro canal). Útil con SMTP en sandbox o
    //       destinatarios sin email automatizado.
    //    En ambos casos, el trigger handle_new_user inserta la fila en
    //    cobradores con rol=admin + tenant_id correcto cuando el user
    //    abre el link y confirma.
    const metadata = {
      tenant_id: tenantId,
      rol: "admin",
      nombre: adminNombre,
      telefono: adminTelefono,
    };

    let adminUserId: string | null = null;
    // userIdParcial: captura el id de auth.users incluso si la
    // respuesta vino malformada (ej. generateLink sin action_link).
    // Si lo tenemos, el rollback lo borra antes de tocar el tenant —
    // sin esto, el trigger handle_new_user ya creó la fila en
    // cobradores apuntando al tenant que queremos borrar, y la FK
    // bloquearía el DELETE tenants dejando el row huérfano.
    let userIdParcial: string | null = null;
    let inviteLink: string | null = null;
    let invErrMsg: string | null = null;

    if (enviarEmail) {
      const { data: invite, error: invErr } = await admin.auth.admin
        .inviteUserByEmail(email, {
          data: metadata,
          redirectTo: body.redirect_to,
        });
      if (invErr || !invite?.user) {
        invErrMsg = invErr?.message ?? "No se creó el usuario";
        userIdParcial = invite?.user?.id ?? null;
      } else {
        adminUserId = invite.user.id;
      }
    } else {
      const { data: gen, error: genErr } = await admin.auth.admin
        .generateLink({
          type: "invite",
          email,
          options: {
            data: metadata,
            redirectTo: body.redirect_to,
          },
        });
      // gen.user puede existir aunque properties.action_link falte —
      // capturamos el id sí o sí para limpiarlo en rollback.
      userIdParcial = gen?.user?.id ?? null;
      if (genErr || !gen?.user || !gen.properties?.action_link) {
        invErrMsg = genErr?.message ?? "No se generó el link de invitación";
      } else {
        adminUserId = gen.user.id;
        inviteLink = gen.properties.action_link;
      }
    }

    if (invErrMsg !== null || adminUserId === null) {
      // Rollback: borrar primero el user de auth.users (cascade limpia
      // cobradores via cobradores.id → auth.users(id) ON DELETE
      // CASCADE), después borrar el tenant.
      if (userIdParcial !== null) {
        await admin.auth.admin.deleteUser(userIdParcial);
      }
      const rollbackOk = await rollbackTenant(admin, tenantId);
      const msg = humanizeAuthError(invErrMsg ?? "Error desconocido");
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
        admin_user_id: adminUserId,
        // invite_link sólo viene cuando enviar_email=false. Para el
        // path email, queda null (no queremos exponer el link en logs).
        invite_link: inviteLink,
        message: enviarEmail
          ? "Tenant creado e invitación enviada por email"
          : "Tenant creado — usá el link para invitar al admin",
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
  // "Error sending invite email" lo emite Supabase Auth cuando el
  // SMTP rechaza el destinatario. Caso típico: Resend en modo sandbox
  // solo permite mandar al email del dueño de la cuenta. Mensaje
  // explícito para que el super_admin no se vuelva loco buscando un
  // bug en el código.
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
