// Edge Function: invitar-cobrador
//
// Permite al admin invitar un nuevo cobrador/admin/admin_cobranza.
//   1. Verifica que el caller tenga rol 'admin' en su tenant.
//   2. Llama a Supabase Auth Admin API para enviar invitación por email.
//   3. Crea la fila en `cobradores` con el rol/prefijo deseado, ligada al
//      tenant del caller.
//
// Despliegue:
//   supabase functions deploy invitar-cobrador
//
// Variables esperadas (configuradas automáticamente por Supabase):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Body esperado (JSON):
//   {
//     "email": "cobrador@empresa.com",
//     "nombre": "Pedro Pérez",
//     "rol": "cobrador" | "admin" | "admin_cobranza",
//     "telefono": "+50588000000",        // opcional
//     "prefijo_recibo": "COB-01"         // opcional, solo para rol cobrador
//   }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface InvitarRequest {
  email: string;
  nombre: string;
  rol: "admin" | "admin_cobranza" | "cobrador";
  telefono?: string;
  prefijo_recibo?: string;
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

    // Cliente con el JWT del caller para verificar quién está invitando.
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar que el caller es admin.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("tenant_id, rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) return jsonError("No estás en la tabla cobradores", 403);
    if (yo.rol !== "admin") {
      return jsonError("Sólo admin puede invitar usuarios", 403);
    }

    // Validar body.
    const body: InvitarRequest = await req.json();
    if (!body.email || !body.nombre || !body.rol) {
      return jsonError("email, nombre y rol son requeridos", 400);
    }
    if (!["admin", "admin_cobranza", "cobrador"].includes(body.rol)) {
      return jsonError("Rol inválido", 400);
    }
    if (body.prefijo_recibo &&
        !/^[A-Z0-9-]{2,16}$/.test(body.prefijo_recibo)) {
      return jsonError(
        "Prefijo debe ser [A-Z0-9-]{2,16}",
        400,
      );
    }

    // Cliente con service_role para llamar a auth.admin.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // 1. Invitar (manda email y crea auth.users row).
    const { data: invite, error: invErr } = await admin.auth.admin
      .inviteUserByEmail(body.email, {
        data: { nombre: body.nombre, rol: body.rol },
      });

    if (invErr) {
      // Si ya existe: opcional permitir actualizar, hoy rechazamos.
      return jsonError(`Auth: ${invErr.message}`, 400);
    }
    if (!invite.user) return jsonError("No se creó el usuario", 500);

    // 2. Crear la fila en cobradores ligada al tenant del caller.
    const { error: cobErr } = await admin.from("cobradores").insert({
      id: invite.user.id,
      tenant_id: yo.tenant_id,
      nombre: body.nombre,
      telefono: body.telefono ?? null,
      rol: body.rol,
      prefijo_recibo:
        body.rol === "cobrador" ? (body.prefijo_recibo ?? null) : null,
      activo: true,
    });

    if (cobErr) {
      // Rollback: borrar el auth user para no dejar huérfano.
      await admin.auth.admin.deleteUser(invite.user.id);
      return jsonError(`No se pudo crear cobrador: ${cobErr.message}`, 500);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        user_id: invite.user.id,
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
