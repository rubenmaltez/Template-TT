import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/audit_lookups_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/audit_changelog.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

class HistorialCambiosWidget extends ConsumerStatefulWidget {
  const HistorialCambiosWidget({
    super.key,
    required this.tabla,
    required this.registroId,
  });
  final String tabla;
  final String registroId;

  @override
  ConsumerState<HistorialCambiosWidget> createState() =>
      _HistorialCambiosWidgetState();
}

class _HistorialCambiosWidgetState
    extends ConsumerState<HistorialCambiosWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialCambiosWidget old) {
    super.didUpdateWidget(old);
    if (old.registroId != widget.registroId || old.tabla != widget.tabla) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT a.id, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at, a.ocurrido_en,
             c.nombre AS user_nombre
        FROM audit_log a
   LEFT JOIN cobradores c ON c.id = a.user_id
       WHERE a.registro_id = ? AND a.tabla = ?
       ORDER BY COALESCE(a.ocurrido_en, a.created_at) DESC
      ''',
      parameters: [widget.registroId, widget.tabla],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Config per-tenant de campos visibles (Fase C). Si una tabla no está en
    // el map, `auditExtraerCambios` cae al default curado por tabla.
    final cfg = ref.watch(appSettingsProvider).auditCamposVisibles;
    // Lookups id→nombre para resolver FK (cobrador, plan, comunidad, etc.).
    // Mientras carga, los FK caen al fallback "(eliminado)" o se ocultan.
    final lookups = ref.watch(auditLookupsProvider).valueOrNull;

    return StreamBuilder(
      stream: _stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        // Inyectamos la tabla del widget en cada row (la query de tabla-única
        // no la selecciona) para que la curaduría del allowlist sepa el origen.
        final eventos = <_EventoVisual>[];
        for (final r in rows) {
          final rowConTabla = {...r, 'tabla': widget.tabla};
          final accion = auditDetectarAccion(rowConTabla);
          final cambios = auditExtraerCambios(
            rowConTabla,
            camposVisibles: cfg[widget.tabla],
            lookups: lookups,
          );
          // Hide-empty: descartar updates que quedan sin cambios tras curaduría
          // (eventos fantasma, ej. delta 0 en cargos_neto). Create/delete/
          // anulacion se muestran aunque tengan pocos campos.
          if (accion == 'update' && cambios.isEmpty) continue;
          eventos.add(_EventoVisual(
            row: rowConTabla,
            accion: accion,
            tabla: widget.tabla,
            cambios: cambios,
          ));
        }

        if (eventos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Sin cambios registrados',
                  style: TextStyle(color: scheme.outline)),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: eventos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _CambioTile(evento: eventos[i]),
        );
      },
    );
  }
}

// Un evento listo para renderizar. `cambios` ya viene curado; `extraLineas`
// son líneas adicionales precompuestas (usado al fusionar un cobro: el
// resultado de la cuota se anexa al card del pago).
class _EventoVisual {
  _EventoVisual({
    required this.row,
    required this.accion,
    required this.tabla,
    required this.cambios,
    this.extraLineas = const [],
  });
  final Map<String, dynamic> row;
  final String accion;
  final String? tabla;
  final List<CampoChange> cambios;
  final List<CampoChange> extraLineas;

}

class _CambioTile extends StatelessWidget {
  const _CambioTile({required this.evento});
  final _EventoVisual evento;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = evento.row;
    // ocurrido_en = hora REAL del dispositivo cuando ocurrió la acción
    // (offline-first). Fallback a created_at (hora server al sincronizar)
    // para filas viejas previas a la Fase B. Ambas en UTC → toLocal().
    final fecha = DateTime.parse(
      (row['ocurrido_en'] ?? row['created_at']) as String,
    ).toLocal();
    final autor =
        row['user_nombre'] as String? ?? row['user_rol'] as String? ?? '—';

    final (IconData icon, Color color, String label) =
        _labelFor(evento.accion, evento.tabla, scheme);

    // El historial muestra SIEMPRE "atributo: estado anterior → nuevo" para
    // que el log sea consistente, sin importar el tipo de acción. En creaciones
    // el anterior es "—"; en eliminaciones el nuevo es "—".
    final filas = [...evento.cambios, ...evento.extraLineas];

    return ExpansionTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(label,
          style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      subtitle: Text(
        '${Fmt.fechaCorta(fecha)} ${Fmt.hora(fecha)} · $autor',
        style: TextStyle(color: scheme.outline, fontSize: 12),
      ),
      children: [
        if (filas.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Sin detalles disponibles',
                style: TextStyle(color: scheme.outline, fontSize: 12)),
          )
        else
          ...filas.map((c) => Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(c.campo,
                          style: TextStyle(
                            color: scheme.outline,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          )),
                    ),
                    Expanded(
                      child: Text(
                        '${c.antes} → ${c.despues}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )),
        const SizedBox(height: 4),
      ],
    );
  }

  // Etiqueta + ícono + color del evento. Si `tabla` viene seteada (timeline
  // unificada), las etiquetas distinguen cuota vs pago; si es null, caen a las
  // genéricas (Creado / Editado / Anulado / Eliminado).
  (IconData, Color, String) _labelFor(
      String accion, String? tabla, ColorScheme scheme) {
    switch (tabla) {
      case 'cuotas':
        return switch (accion) {
          'create' => (Icons.receipt_long, scheme.tertiary, 'Cuota generada'),
          'delete' => (Icons.delete_outline, scheme.error, 'Cuota eliminada'),
          'anulacion' => (Icons.block, scheme.error, 'Cuota anulada'),
          _ => (Icons.edit, scheme.primary, 'Cuota actualizada'),
        };
      case 'pagos':
        return switch (accion) {
          'create' => (Icons.payments, scheme.tertiary, 'Pago registrado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Pago eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Pago anulado'),
          _ => (Icons.edit, scheme.primary, 'Pago editado'),
        };
      case 'recibos':
        return switch (accion) {
          'create' => (Icons.receipt, scheme.tertiary, 'Recibo emitido'),
          'delete' => (Icons.delete_outline, scheme.error, 'Recibo eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Recibo anulado'),
          _ => (Icons.edit, scheme.primary, 'Recibo actualizado'),
        };
      case 'clientes':
        return switch (accion) {
          'create' =>
            (Icons.person_add_alt, scheme.tertiary, 'Cliente creado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Cliente eliminado'),
          _ => (Icons.edit, scheme.primary, 'Cliente actualizado'),
        };
      case 'contratos':
        return switch (accion) {
          'create' => (Icons.assignment, scheme.tertiary, 'Contrato creado'),
          'delete' =>
            (Icons.delete_outline, scheme.error, 'Contrato eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Contrato anulado'),
          _ => (Icons.edit, scheme.primary, 'Contrato actualizado'),
        };
      case 'visitas':
        return switch (accion) {
          'create' =>
            (Icons.where_to_vote_outlined, scheme.tertiary, 'Visita registrada'),
          'delete' => (Icons.delete_outline, scheme.error, 'Visita eliminada'),
          _ => (Icons.edit, scheme.primary, 'Visita actualizada'),
        };
      case 'fotos_cliente':
        return switch (accion) {
          'create' =>
            (Icons.add_a_photo_outlined, scheme.tertiary, 'Foto agregada'),
          'delete' => (Icons.delete_outline, scheme.error, 'Foto eliminada'),
          _ => (Icons.edit, scheme.primary, 'Foto actualizada'),
        };
      case 'planes':
        return switch (accion) {
          'create' => (Icons.add_circle_outline, scheme.tertiary, 'Plan creado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Plan eliminado'),
          _ => (Icons.edit, scheme.primary, 'Plan actualizado'),
        };
      default:
        return switch (accion) {
          'create' => (Icons.add_circle_outline, scheme.tertiary, 'Creado'),
          'delete' => (Icons.delete_outline, scheme.error, 'Eliminado'),
          'anulacion' => (Icons.block, scheme.error, 'Anulado'),
          _ => (Icons.edit, scheme.primary, 'Editado'),
        };
    }
  }
}

// ---------------------------------------------------------------------------
// Timeline unificada de una cuota: mezcla los cambios de la propia cuota
// (generación + cambios de estado/monto_pagado) con los cambios de TODOS los
// pagos asociados (registro / anulación / edición). Una sola línea de tiempo
// cronológica para entender "qué le pasó a esta cuota".
// ---------------------------------------------------------------------------
class HistorialCuotaWidget extends ConsumerStatefulWidget {
  const HistorialCuotaWidget({super.key, required this.cuotaId});
  final String cuotaId;

  @override
  ConsumerState<HistorialCuotaWidget> createState() =>
      _HistorialCuotaWidgetState();
}

class _HistorialCuotaWidgetState extends ConsumerState<HistorialCuotaWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialCuotaWidget old) {
    super.didUpdateWidget(old);
    if (old.cuotaId != widget.cuotaId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // Entries de la cuota + sus pagos + los recibos de esos pagos, unidas en
    // una sola query. El recibo es nieto de la cuota (cuota → pago → recibo),
    // así que esto extiende deliberadamente la regla de profundidad: lo
    // permitimos porque el recibo es hoja 1:1 del pago y su número/anulación
    // son parte del rastro de dinero (ver #5 + nota en CLAUDE.md). No agrega
    // sus propias hijas (no las tiene), así que no abre la puerta a nietas
    // genéricas.
    //
    // AUDIENCIA: este timeline solo tiene data para admin / admin_cobranza /
    // super_admin impersonando — son los únicos buckets que sincronizan
    // `audit_log` (ver sync-rules.yaml; `por_cobrador` NO lo baja, así que para
    // un cobrador el widget muestra "Sin movimientos", igual que antes de #5).
    // Esos roles además sincronizan TODOS los pagos (incl. anulados), así que
    // el `pago_id IN (SELECT ... FROM pagos)` de abajo siempre resuelve.
    //
    // El recibo se vincula por el `pago_id` DENTRO del snapshot JSON del
    // audit_log (json_extract), NO por un JOIN a la tabla `recibos`: leer el
    // snapshot evita depender de que la fila del recibo siga existiendo y es el
    // mismo patrón que HistorialClienteWidget. json_extract corre sobre SQLite
    // local (válido en ps.db.watch).
    //
    // La subquery `IN (SELECT ...)` corre sobre SQLite local (válida acá; la
    // restricción de "sin subqueries" aplica a las SYNC RULES, no a las
    // queries de `ps.db.watch`). Orden ASC por ocurrido_en (device time, con
    // fallback a created_at) = cronológico real del cobro hacia adelante. Es
    // CLAVE que coincida con el campo que usa la ventana de agrupación de
    // _construirEventos (ocurrido_en), sino el pago y el update de su cuota se
    // desordenan y no se agrupan.
    return ps.db.watch(
      '''
      SELECT a.id, a.tabla, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at, a.ocurrido_en,
             c.nombre AS user_nombre
        FROM audit_log a
   LEFT JOIN cobradores c ON c.id = a.user_id
       WHERE (a.tabla = 'cuotas' AND a.registro_id = ?)
          OR (a.tabla = 'pagos' AND a.registro_id IN (
                SELECT id FROM pagos WHERE cuota_id = ?
              ))
          OR (a.tabla = 'recibos' AND json_extract(
                COALESCE(a.valor_nuevo, a.valor_anterior), '\$.pago_id'
              ) IN (SELECT id FROM pagos WHERE cuota_id = ?))
       ORDER BY COALESCE(a.ocurrido_en, a.created_at) ASC,
                CASE a.tabla
                  WHEN 'pagos' THEN 0 WHEN 'recibos' THEN 1 ELSE 2
                END ASC
      ''',
      parameters: [widget.cuotaId, widget.cuotaId, widget.cuotaId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Config per-tenant de campos visibles (Fase C).
    final cfg = ref.watch(appSettingsProvider).auditCamposVisibles;
    // Lookups id→nombre para resolver FK (cobrador, plan, comunidad, etc.).
    final lookups = ref.watch(auditLookupsProvider).valueOrNull;

    return StreamBuilder(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Error al cargar el historial',
                  style: TextStyle(color: scheme.error)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        final eventos = _construirEventos(rows, cfg, lookups);

        if (eventos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Sin movimientos registrados',
                  style: TextStyle(color: scheme.outline)),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: eventos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _CambioTile(evento: eventos[i]),
        );
      },
    );
  }

  // Pre-procesa las filas crudas del audit_log en una lista de eventos
  // visuales, aplicando:
  //  1. Curaduría + hide-empty (igual que la timeline de tabla-única).
  //  2. "Un cobro = un solo evento": un pago/create + las cuota/update que
  //     genera (mismo user_id y ocurrido_en —fallback created_at— dentro de
  //     ≤3s) se fusionan en un solo card "Pago registrado" con el resultado
  //     de la cuota anexado.
  //     Las cuota/update absorbidas NO se muestran por separado.
  // El orden cronológico ASC se preserva (el card del grupo toma la posición
  // del pago/create).
  List<_EventoVisual> _construirEventos(
    List<Map<String, dynamic>> rows,
    Map<String, Set<String>> cfg,
    AuditLookups? lookups,
  ) {
    const ventana = Duration(seconds: 3);

    // Parseamos la hora de la acción una vez para el matching de ventana.
    // Usamos ocurrido_en (hora de dispositivo) con fallback a created_at:
    // es la que ahora marca el orden real del cobro offline-first.
    final parsed = rows.map((r) {
      final raw = (r['ocurrido_en'] ?? r['created_at']) as String? ?? '';
      final dt = DateTime.tryParse(raw);
      return (row: r, ts: dt);
    }).toList();

    // Índices de cuota/update ya absorbidos por un grupo de pago.
    final absorbidos = <int>{};
    // Mapa pago/create (índice) → cuota/update (índices) que absorbió. Cada
    // cuota/update se asigna a UN solo pago (el primero que la matchea), para
    // no cruzar las líneas de estado entre dos cobros a la misma cuota en <3s.
    final absorbidoPorPago = <int, List<int>>{};

    // Para cada pago/create, buscar cuota/update del mismo user dentro de la
    // ventana, y marcarlas como absorbidas anexando su resultado.
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final row = p.row;
      if (row['tabla'] != 'pagos') continue;
      final accion = auditDetectarAccion(row);
      if (accion != 'create') continue;
      final pagoTs = p.ts;
      final pagoUser = row['user_id'];
      if (pagoTs == null) continue;

      for (var j = 0; j < parsed.length; j++) {
        if (j == i || absorbidos.contains(j)) continue;
        final q = parsed[j];
        final qr = q.row;
        if (qr['tabla'] != 'cuotas') continue;
        if (auditDetectarAccion(qr) != 'update') continue;
        if (qr['user_id'] != pagoUser) continue;
        final qts = q.ts;
        if (qts == null) continue;
        if ((qts.difference(pagoTs)).abs() > ventana) continue;
        absorbidos.add(j);
        (absorbidoPorPago[i] ??= []).add(j);
      }
    }

    final eventos = <_EventoVisual>[];

    for (var i = 0; i < parsed.length; i++) {
      if (absorbidos.contains(i)) continue;
      final row = parsed[i].row;
      final tabla = row['tabla'] as String?;
      final accion = auditDetectarAccion(row);
      final cambios = auditExtraerCambios(
        row,
        camposVisibles: cfg[tabla],
        lookups: lookups,
      );

      // Hide-empty: descartar updates sin cambios tras curaduría. No aplica a
      // create/delete/anulacion.
      if (accion == 'update' && cambios.isEmpty) continue;

      // Si es un pago/create, anexar el resultado SOLO de las cuota/update que
      // ESTE pago absorbió (no re-matchear por ventana → evita cruzar dos
      // cobros a la misma cuota dentro de los 3s).
      final extra = <CampoChange>[];
      if (tabla == 'pagos' && accion == 'create') {
        for (final j in absorbidoPorPago[i] ?? const <int>[]) {
          extra.addAll(
            auditExtraerCambios(
              parsed[j].row,
              camposVisibles: cfg['cuotas'],
              lookups: lookups,
            ),
          );
        }
      }

      eventos.add(_EventoVisual(
        row: row,
        accion: accion,
        tabla: tabla,
        cambios: cambios,
        extraLineas: extra,
      ));
    }

    return eventos;
  }
}

// ---------------------------------------------------------------------------
// Timeline unificada de un CLIENTE: mezcla los cambios del propio cliente con
// los de sus hijas DIRECTAS — visitas, fotos y contratos. Profundidad = UN
// nivel: NO baja a cuotas/pagos (nietas/bisnietas), que viven en el log de su
// cuota. Para los contratos (hija "contenedora") se muestran solo eventos de
// superficie (alta/baja/estado/reasignación de cobrador), no sus ediciones
// puntuales de precio/día/plan — esas están en el log del contrato. Ver
// `kAuditCamposSuperficie`.
//
// El link a las hijas se lee del snapshot JSON (`json_extract` sobre
// valor_nuevo con fallback a valor_anterior), NO de un `IN (SELECT...)`: así
// una hija borrada físico (ej. una foto) sigue apareciendo en el historial,
// porque su cliente_id vive dentro del snapshot aunque la fila ya no exista en
// la tabla. json_extract corre sobre SQLite local (válido en `ps.db.watch`).
// ---------------------------------------------------------------------------
class HistorialClienteWidget extends ConsumerStatefulWidget {
  const HistorialClienteWidget({super.key, required this.clienteId});
  final String clienteId;

  @override
  ConsumerState<HistorialClienteWidget> createState() =>
      _HistorialClienteWidgetState();
}

class _HistorialClienteWidgetState
    extends ConsumerState<HistorialClienteWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialClienteWidget old) {
    super.didUpdateWidget(old);
    if (old.clienteId != widget.clienteId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // El cliente (por registro_id) + sus hijas directas (visitas/fotos/
    // contratos) localizadas por el cliente_id DENTRO del snapshot JSON. Sin
    // LIMIT: el historial muestra la vida completa del cliente. Orden DESC =
    // lo más reciente primero.
    return ps.db.watch(
      '''
      SELECT a.id, a.tabla, a.accion, a.campo,
             a.valor_anterior, a.valor_nuevo,
             a.user_id, a.user_rol, a.created_at, a.ocurrido_en,
             c.nombre AS user_nombre
        FROM audit_log a
   LEFT JOIN cobradores c ON c.id = a.user_id
       WHERE (a.tabla = 'clientes' AND a.registro_id = ?)
          OR (a.tabla IN ('visitas', 'fotos_cliente', 'contratos')
              AND json_extract(
                    COALESCE(a.valor_nuevo, a.valor_anterior),
                    '\$.cliente_id'
                  ) = ?)
       ORDER BY COALESCE(a.ocurrido_en, a.created_at) DESC
      ''',
      parameters: [widget.clienteId, widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = ref.watch(appSettingsProvider).auditCamposVisibles;
    final lookups = ref.watch(auditLookupsProvider).valueOrNull;

    return StreamBuilder(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Error al cargar el historial',
                  style: TextStyle(color: scheme.error)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        final eventos = <_EventoVisual>[];
        for (final r in rows) {
          final tabla = r['tabla'] as String?;
          final accion = auditDetectarAccion(r);
          // Hijas "contenedoras" (contrato): solo superficie. Un update que
          // solo tocó campos no-superficie queda con `cambios` vacío y se
          // oculta. Para las demás tablas, `superficie` es null → cae al
          // allowlist normal (cfg per-tenant o el default por tabla).
          final superficie = kAuditCamposSuperficie[tabla];
          final cambios = auditExtraerCambios(
            r,
            camposVisibles: superficie ?? cfg[tabla],
            lookups: lookups,
          );
          if (accion == 'update' && cambios.isEmpty) continue;
          eventos.add(_EventoVisual(
            row: r,
            accion: accion,
            tabla: tabla,
            cambios: cambios,
          ));
        }

        if (eventos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('Sin cambios registrados',
                  style: TextStyle(color: scheme.outline)),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: eventos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _CambioTile(evento: eventos[i]),
        );
      },
    );
  }
}
