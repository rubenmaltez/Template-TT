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
import { corsHeaders, jsonError } from "../_shared/response.ts";

interface EliminarRequest {
  cobrador_id: string;
}

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
    //
    // Además de cobrador_id (creador), contamos las columnas de
    // atribución (anulado_por, aplicado_por) porque son FK ON DELETE
    // SET NULL — sin esta protección, eliminar al super_admin que anuló
    // 5000 pagos borraría la atribución de quién los anuló.
    const [
      pagosRes,
      recibosRes,
      cargosRes,
      clientesRes,
      pagosAnuladosPor,
      recibosAnuladosPor,
      cargosAplicadosPor,
    ] = await Promise.all([
      admin.from("pagos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("recibos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("cargos_extra").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("clientes").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("pagos").select("id", { count: "exact", head: true })
        .eq("anulado_por", body.cobrador_id),
      admin.from("recibos").select("id", { count: "exact", head: true })
        .eq("anulado_por", body.cobrador_id),
      admin.from("cargos_extra").select("id", { count: "exact", head: true })
        .eq("aplicado_por", body.cobrador_id),
    ]);

    // Si alguna count query falla, abortamos por defensiveness — no
    // queremos eliminar pensando que el count era 0 cuando en realidad
    // hubo un error.
    const allRes = [
      pagosRes,
      recibosRes,
      cargosRes,
      clientesRes,
      pagosAnuladosPor,
      recibosAnuladosPor,
      cargosAplicadosPor,
    ];
    for (const r of allRes) {
      if (r.error) {
        console.error("eliminar: count query falló", r.error);
        return jsonError("Error contando historial del usuario", 500);
      }
    }

    const pagos = pagosRes.count ?? 0;
    const recibos = recibosRes.count ?? 0;
    const cargos = cargosRes.count ?? 0;
    const clientes = clientesRes.count ?? 0;
    const pagosAnul = pagosAnuladosPor.count ?? 0;
    const recibosAnul = recibosAnuladosPor.count ?? 0;
    const cargosApl = cargosAplicadosPor.count ?? 0;

    // Tablas agregadas DESPUÉS del guard original (visitas, fotos, tickets,
    // inventario): el delete perdía atribución en silencio (FK SET NULL) o
    // reventaba con FK violation (visitas.cobrador_id NOT NULL). Conteo
    // TOLERANTE: 42P01 (relation does not exist — migraciones 0099-0107 sin
    // correr) cuenta como 0 para no bloquear el delete en una DB sin esos
    // módulos; cualquier OTRO error sí aborta (defensiveness del guard base).
    const countOpcional = async (
      tabla: string,
      columna: string,
    ): Promise<number | null> => {
      const r = await admin.from(tabla)
        .select("id", { count: "exact", head: true })
        .eq(columna, body.cobrador_id);
      if (r.error) {
        if (r.error.code === "42P01") return 0; // tabla aún no deployada
        console.error(`eliminar: count ${tabla}.${columna} falló`, r.error);
        return null; // error real → abortar
      }
      return r.count ?? 0;
    };

    const extras = await Promise.all([
      countOpcional("visitas", "cobrador_id"),
      countOpcional("fotos_cliente", "created_by"),
      countOpcional("tickets", "asignado_a"),
      countOpcional("tickets", "creado_por"),
      countOpcional("ticket_eventos", "hecho_por"),
      countOpcional("ticket_materiales", "hecho_por"),
      countOpcional("inv_movimientos", "hecho_por"),
      countOpcional("inv_ubicaciones", "cobrador_id"),
    ]);
    if (extras.some((n) => n === null)) {
      return jsonError("Error contando historial del usuario", 500);
    }
    const [
      visitas,
      fotos,
      ticketsAsig,
      ticketsCre,
      eventos,
      materiales,
      movimientos,
      ubicaciones,
    ] = extras as number[];
    const totalExtras = visitas + fotos + ticketsAsig + ticketsCre +
      eventos + materiales + movimientos + ubicaciones;

    const total = pagos + recibos + cargos + clientes +
      pagosAnul + recibosAnul + cargosApl + totalExtras;
    if (total > 0) {
      const partesExtras = [
        visitas > 0 ? `${visitas} visitas` : null,
        fotos > 0 ? `${fotos} fotos` : null,
        (ticketsAsig + ticketsCre) > 0
          ? `${ticketsAsig + ticketsCre} tickets`
          : null,
        eventos > 0 ? `${eventos} eventos de ticket` : null,
        materiales > 0 ? `${materiales} consumos de material` : null,
        movimientos > 0 ? `${movimientos} movimientos de inventario` : null,
        ubicaciones > 0 ? `${ubicaciones} ubicaciones de custodia` : null,
      ].filter((s) => s !== null);
      const sufijo = partesExtras.length > 0
        ? `, ${partesExtras.join(", ")}`
        : "";
      return jsonError(
        "No se puede eliminar: tiene historial operativo " +
          `(${pagos} pagos creados, ${recibos} recibos, ${cargos} cargos, ` +
          `${clientes} clientes asignados, ${pagosAnul} pagos anulados ` +
          `por él, ${recibosAnul} recibos anulados por él, ${cargosApl} ` +
          `cargos aplicados por él${sufijo}). Usá 'Desactivar' en su lugar ` +
          "para preservar el historial.",
        409,
      );
    }

    // Audit log ANTES del delete por defensiveness: si el insert falla,
    // abortamos sin haber borrado nada y el super_admin puede reintentar.
    // El audit row sobrevive al delete de auth.users (no hay FK al revés).
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
