// Edge Function: crear-tenant
//
// Crea un tenant completo en un solo click desde el panel super_admin:
//   1. Inserta el row en `tenants` (el trigger habilita los módulos base).
//   2. Habilita módulos no-base extra vía set_tenant_modulo RPC.
//   3. Crea al admin con metadata. Dos modos según enviar_email:
//      - true  → inviteUserByEmail (manda email automático con link).
//      - false → createUser con password aleatoria + email_confirm=true
//                (no manda email; devuelve admin_password para que el
//                super_admin lo comparta por otro canal). Workaround
//                para SMTP en sandbox o destinatarios sin email
//                automatizado. Mismo patrón que forzar-password-cobrador.
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
//   { ok: true, tenant_id, admin_user_id, admin_password?, message }
//   admin_password sólo viene cuando enviar_email=false — es la
//   contraseña generada para el admin, que el super_admin tiene que
//   compartir por canal seguro (no queda guardada en ningún lado).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface CrearTenantRequest {
  tenant_nombre: string;
  admin_email: string;
  admin_nombre: string;
  admin_telefono?: string;
  modulos_extra?: string[];
  redirect_to?: string;
  // Si false, no manda email — crea al user con una password aleatoria
  // (email_confirm=true para skipear el email de verificación) y la
  // devuelve en admin_password. El super_admin la comparte por otro
  // canal y el admin se loguea normal con email+password. Workaround
  // del bug PKCE+cross-browser para links generados manualmente.
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
    // para activar el flow de createUser+password. Falsey check tolera
    // null/undefined además de false.
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
    // - inviteUserByEmail ya falla nativamente si existe (path email).
    // - createUser también falla con "user already exists" (path no-email).
    // Hacemos el check antes de cualquier creación para devolver el
    // error en español sin disparar el rollback de tenant.
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
    //    a) enviarEmail=true → inviteUserByEmail (manda email con
    //       link de set-password).
    //    b) enviarEmail=false → createUser con password aleatoria +
    //       email_confirm=true (no manda nada). El super_admin recibe
    //       la password en la respuesta y la pasa por otro canal —
    //       el admin se loguea normal por /login. Evita el problema
    //       PKCE+cross-browser de los magic-links generados a mano.
    //    En ambos casos, el trigger handle_new_user inserta la fila
    //    en cobradores con rol=admin + tenant_id correcto al crearse
    //    el row en auth.users.
    const metadata = {
      tenant_id: tenantId,
      rol: "admin",
      nombre: adminNombre,
      telefono: adminTelefono,
    };

    let adminUserId: string | null = null;
    // userIdParcial: captura el id de auth.users incluso si algo en
    // la respuesta vino malformado. Si lo tenemos, el rollback lo
    // borra antes de tocar el tenant — sin esto, el trigger
    // handle_new_user ya creó la fila en cobradores apuntando al
    // tenant que queremos borrar, y la FK bloquearía el DELETE
    // tenants dejando un row huérfano en auth.users.
    let userIdParcial: string | null = null;
    let adminPassword: string | null = null;
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
      // Generamos la password ANTES de createUser. Si la genera el
      // server, no la conoce nadie más — la response es la única
      // oportunidad del super_admin de verla.
      const generated = generarPasswordSegura();
      const { data: created, error: createErr } = await admin.auth.admin
        .createUser({
          email,
          password: generated,
          user_metadata: metadata,
          // email_confirm=true skipea el email de verificación de
          // Supabase. El user queda confirmado y puede loguearse ya
          // mismo con la password generada. Modelo de confianza:
          // el super_admin verifica la propiedad del email
          // out-of-band (llamada/whatsapp al ISP); misma postura que
          // forzar-password-cobrador para users existentes.
          email_confirm: true,
        });
      userIdParcial = created?.user?.id ?? null;
      if (createErr || !created?.user) {
        invErrMsg = createErr?.message ?? "No se creó el usuario";
      } else {
        adminUserId = created.user.id;
        adminPassword = generated;
      }
    }

    if (invErrMsg !== null || adminUserId === null) {
      // Rollback: borrar primero el user de auth.users (cascade limpia
      // cobradores via cobradores.id → auth.users(id) ON DELETE
      // CASCADE), después borrar el tenant.
      //
      // Si deleteUser falla (raro: blip de red entre createUser y
      // este punto), la FK cobradores.tenant_id va a bloquear el
      // delete del tenant — terminamos con auth.users huérfano
      // apuntando a un tenant inexistente. Loggeamos pero no
      // abortamos: el rollbackTenant siguiente devolverá su propio
      // error si la FK se queja, y el orphan_tenant_id en la
      // respuesta le dice al super_admin que hay que limpiar.
      if (userIdParcial !== null) {
        const { error: delErr } = await admin.auth.admin
          .deleteUser(userIdParcial);
        if (delErr) {
          console.error(
            `crear-tenant deleteUser falló en rollback (user=${userIdParcial}, ` +
              `tenant=${tenantId}): ${delErr.message}`,
          );
        }
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
        // Eco del email — el cliente lo necesita para mostrar el
        // bloque "email + password" sin tener que re-leerlo del form
        // (que ya pudo ser disposed).
        admin_email: email,
        // admin_password sólo viene cuando enviar_email=false. Es la
        // única oportunidad del super_admin de verla — no queda
        // guardada en ningún lado, y si la pierde tiene que ir a
        // 'Forzar contraseña' desde el detalle del miembro.
        admin_password: adminPassword,
        message: enviarEmail
          ? "Tenant creado e invitación enviada por email"
          : "Tenant creado — compartí las credenciales con el admin",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente: si el throw ocurrió tras
    // generar la password aleatoria, ésta podría aparecer en el stack
    // trace según cómo Deno formatee la excepción (depende de
    // --inspect / --log-level). Loggeamos en server para diagnosticar
    // y devolvemos un mensaje genérico al cliente.
    console.error("crear-tenant unhandled error:", e);
    return jsonError("Error interno — revisá los logs de la función", 500);
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
