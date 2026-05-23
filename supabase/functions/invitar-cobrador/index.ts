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
// Dos modos según `enviar_email`:
//   - true (default) → inviteUserByEmail (manda email automático con
//                      link de set-password).
//   - false          → createUser con password aleatoria + email_confirm
//                      (no manda email; devuelve `nueva_password` para
//                      que el caller la comparta por canal seguro).
//                      Workaround para SMTP en sandbox o destinatarios
//                      sin email automatizado. Mismo patrón que
//                      crear-tenant + reenviar-invitacion.
//
// Cuando el invitado abre el email (o se loguea directo con la password
// generada), el trigger `handle_new_user` (migración 0024) crea su fila
// en `cobradores` con el metadata que pasamos acá.
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
//     "tenant_id": "<uuid>",          // REQUERIDO sólo si caller es super_admin
//     "enviar_email": true            // opcional, default true
//   }
//
// Respuesta éxito:
//   { ok: true, user_id, tenant_id, nueva_password?, message }
//   nueva_password sólo viene cuando enviar_email=false — es la
//   contraseña generada para el invitado, que el caller tiene que
//   compartir por canal seguro (no queda guardada en ningún lado).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";
import { generarPasswordSegura } from "../_shared/passwords.ts";

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
  // Si false, no manda email — crea al user con una password aleatoria
  // (email_confirm=true para skipear el email de verificación) y la
  // devuelve en `nueva_password`. El caller la comparte por otro canal
  // y el invitado se loguea normal con email+password. Workaround del
  // problema PKCE+cross-browser de los magic-links generados a mano.
  enviar_email?: boolean;
}

const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

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
    // Default true: el caller tiene que pedir explícitamente "no email"
    // para activar el flow de createUser+password. Falsey check tolera
    // null/undefined además de false.
    const enviarEmail = body.enviar_email !== false;

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

    // Pre-flight: chequear que el email no exista en auth.users.
    // - inviteUserByEmail falla nativamente si existe (path email).
    // - createUser también falla con "user already exists" (path no-email).
    // El check anticipado evita un round-trip al auth provider y
    // devuelve el error en español de una. Mismo patrón que crear-tenant.
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

    // Metadata compartida entre los 2 paths. El trigger handle_new_user
    // la lee para crear la fila en `cobradores` cuando se crea el row
    // en auth.users (sea por inviteUserByEmail o createUser).
    const metadata = {
      tenant_id: targetTenantId,
      rol: body.rol,
      nombre: nombre,
      telefono: telefono === "" ? null : telefono,
      prefijo_recibo: body.rol === "cobrador"
        ? (body.prefijo_recibo ?? null)
        : null,
    };

    let nuevoUserId: string | null = null;
    let nuevaPassword: string | null = null;

    if (enviarEmail) {
      // Path email: Supabase manda invite con link de set-password.
      // redirect_to: si lo manda el cliente, lo respetamos (debería
      // tener `?flow=invite` para que el app route a /set-password).
      // Si no, Supabase usa el Site URL configurado.
      const { data: invite, error: invErr } = await admin.auth.admin
        .inviteUserByEmail(email, {
          data: metadata,
          redirectTo: body.redirect_to,
        });

      if (invErr) {
        return jsonError(humanizeAuthError(invErr.message), 400);
      }
      if (!invite.user) return jsonError("No se creó el usuario", 500);
      nuevoUserId = invite.user.id;
    } else {
      // Path no-email: generamos la password ANTES de createUser. Si la
      // genera el server, no la conoce nadie más — la response es la
      // única oportunidad del caller de verla. email_confirm=true
      // skipea el email de verificación: el user queda confirmado y
      // puede loguearse ya mismo. Modelo de confianza: el caller
      // verifica la propiedad del email out-of-band (llamada/whatsapp);
      // misma postura que crear-tenant y forzar-password-cobrador.
      const generated = generarPasswordSegura();
      const { data: created, error: createErr } = await admin.auth.admin
        .createUser({
          email,
          password: generated,
          user_metadata: metadata,
          email_confirm: true,
        });

      if (createErr) {
        return jsonError(humanizeAuthError(createErr.message), 400);
      }
      if (!created.user) return jsonError("No se creó el usuario", 500);
      nuevoUserId = created.user.id;
      nuevaPassword = generated;
    }

    return new Response(
      JSON.stringify({
        ok: true,
        user_id: nuevoUserId,
        tenant_id: targetTenantId,
        // nueva_password sólo viene cuando enviar_email=false. Es la
        // única oportunidad del caller de verla — no queda guardada
        // en ningún lado, y si la pierde tiene que ir a 'Forzar
        // contraseña' desde el detalle del miembro.
        nueva_password: nuevaPassword,
        message: enviarEmail
          ? "Invitación enviada por email"
          : "Usuario creado — compartí las credenciales por canal seguro",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente — puede leakear stack o data
    // sensible. Loggeamos server-side y devolvemos mensaje genérico.
    //
    // Importante: en el modo no-email tenemos la `generated` password
    // en scope. Si el SDK alguna vez incluyera el request body en el
    // Error (vía `cause` o similar), `e` completo podría contener la
    // password — los logs del Dashboard son consultables por cualquier
    // colaborador del proyecto. Solo logueamos `e.message`, no el
    // objeto entero, para minimizar la superficie. Defense in depth.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("invitar-cobrador unhandled error:", safeMessage);
    return jsonError("Error interno — revisá los logs de la función", 500);
  }
});

