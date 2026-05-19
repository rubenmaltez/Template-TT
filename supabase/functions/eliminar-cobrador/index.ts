// Edge Function: eliminar-cobrador
//
// Elimina permanentemente a un miembro de un tenant. Pensado para limpiar
// usuarios sin operación (pending invites viejos, admins de prueba que
// nunca trabajaron, etc.). Para usuarios con historial real, la opción
// correcta es 'Desactivar' (preserva pagos / recibos / auditoría).
//
// Comportamiento:
//   - Cuenta el historial operativo del usuario (pagos / recibos /
//     cargos / clientes activos).
//   - Si hay CUALQUIER fila > 0, bloquea con un mensaje claro sugiriendo
//     desactivar en vez. Esto evita FK violations + audit huérfano.
//   - Si todo está limpio, captura el snapshot mínimo para audit y
//     llama a auth.admin.deleteUser (cascadea cobradores).
//
// Guards:
//   - Sólo super_admin.
//   - No se borra a sí mismo.
//   - No se borra a otro super_admin.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface EliminarRequest {
  cobrador_id: string;
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

    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede eliminar usuarios", 403);
    }

    const body: EliminarRequest = await req.json();
    if (!body.cobrador_id) {
      return jsonError("cobrador_id requerido", 400);
    }
    if (body.cobrador_id === user.id) {
      return jsonError("No podés eliminarte a vos mismo", 400);
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Snapshot para audit + verificar que no es super_admin.
    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol, nombre")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("eliminar: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError("No se puede eliminar a otro super_admin", 400);
    }

    // Contar operaciones — si hay historial operativo, bloqueamos y
    // sugerimos desactivar en vez. Evita FK violations + audit huérfano.
    // Pagos/recibos cuentan incluso anulados porque siguen siendo
    // historial relevante.
    const [pagosRes, recibosRes, cargosRes, clientesRes] = await Promise.all([
      admin.from("pagos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("recibos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("cargos_extra").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("clientes").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
    ]);

    const pagos = pagosRes.count ?? 0;
    const recibos = recibosRes.count ?? 0;
    const cargos = cargosRes.count ?? 0;
    const clientes = clientesRes.count ?? 0;
    const total = pagos + recibos + cargos + clientes;
    if (total > 0) {
      return jsonError(
        "No se puede eliminar: tiene historial operativo " +
          `(${pagos} pagos, ${recibos} recibos, ${cargos} cargos, ` +
          `${clientes} clientes asignados). Usá 'Desactivar' en su lugar ` +
          "para preservar el historial.",
        409,
      );
    }

    // Audit log ANTES del delete — necesitamos tenant_id que después
    // cascadea al borrado.
    const { error: auditErr } = await admin.from("audit_log").insert({
      tenant_id: tc.tenant_id,
      tabla: "auth.users",
      registro_id: body.cobrador_id,
      campo: "eliminar",
      valor_anterior: { nombre: tc.nombre, rol: tc.rol },
      valor_nuevo: { action: "deleted_user" },
      user_id: user.id,
      user_rol: "super_admin",
    });
    if (auditErr) {
      console.error("eliminar: audit insert falló", auditErr);
      return jsonError(
        "Error interno: no se pudo registrar la operación. Abortado por " +
          "seguridad — intentá de nuevo.",
        500,
      );
    }

    // Delete (cascadea la fila de cobradores por la FK).
    const { error: delErr } = await admin.auth.admin.deleteUser(
      body.cobrador_id,
    );
    if (delErr) {
      console.error("eliminar: deleteUser falló", delErr);
      return jsonError(
        `No se pudo eliminar el usuario: ${delErr.message}`,
        500,
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Usuario eliminado",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    console.error("eliminar-cobrador: unhandled", e);
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
