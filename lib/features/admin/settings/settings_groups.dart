import 'package:flutter/material.dart';

/// Definiciones declarativas de los grupos (tarjetas-sección) del panel de
/// settings. Cada tab del panel se arma a partir de la lista de grupos de su
/// categoría: el screen recorre estos grupos, busca cada `clave` en el mapa
/// de settings sincronizado y renderiza sólo las que existen.
///
/// La separación tab → grupos → settings vive acá para que el screen quede
/// declarativo: agregar/mover un setting de grupo es editar estos datos, no
/// la lógica de render.

/// Un setting dentro de un grupo. Puede declarar `hijos`: las claves de los
/// settings que SOLO se revelan (animado) cuando este setting (un toggle
/// padre) está en ON.
class SettingEntry {
  const SettingEntry(this.clave, {this.hijos = const []});

  final String clave;

  /// Claves de settings hijos que dependen de que este (toggle padre) esté ON.
  /// Si está vacío, el setting es un campo plano sin dependientes.
  final List<String> hijos;

  bool get tieneHijos => hijos.isNotEmpty;
}

/// Una tarjeta-sección: header (ícono + título) + lista de settings.
class SettingGroup {
  const SettingGroup({
    required this.titulo,
    required this.icono,
    required this.entradas,
    this.subtitulo,
  });

  final String titulo;
  final IconData icono;
  final String? subtitulo;
  final List<SettingEntry> entradas;

  /// Todas las claves que el grupo puede llegar a mostrar (padres + hijos).
  /// Se usa para decidir si el grupo tiene al menos un setting presente en el
  /// mapa sincronizado (si ninguna existe, el grupo no se renderiza).
  Iterable<String> get todasLasClaves sync* {
    for (final e in entradas) {
      yield e.clave;
      yield* e.hijos;
    }
  }
}

/// Grupos de la tab Empresa. (El `_LogoUploadWidget` se inserta aparte arriba
/// del primer grupo desde el screen, sólo si es admin.)
const kGruposEmpresa = <SettingGroup>[
  SettingGroup(
    titulo: 'Datos de la empresa',
    icono: Icons.business,
    entradas: [
      SettingEntry('empresa.nombre'),
      SettingEntry('empresa.direccion'),
      SettingEntry('empresa.telefono'),
      SettingEntry('empresa.ruc'),
      SettingEntry('empresa.whatsapp'),
    ],
  ),
];

/// Grupos de la tab Cobranza. Los settings super_admin-only (comprobante,
/// foto, pantallas opcionales) ya NO viven acá: se movieron a la tab Avanzado.
const kGruposCobranza = <SettingGroup>[
  SettingGroup(
    titulo: 'Reglas de cobro',
    icono: Icons.rule,
    entradas: [
      SettingEntry('cobranza.dias_gracia'),
      SettingEntry('cobranza.dias_cuotas_visibles'),
      SettingEntry('cobranza.pago_parcial'),
      SettingEntry('cobranza.pago_adelantado'),
    ],
  ),
  SettingGroup(
    titulo: 'Permisos',
    icono: Icons.lock_open,
    entradas: [
      SettingEntry('cobranza.cobrador_edita_fecha'),
      SettingEntry('cobranza.cobrador_anula_cobros'),
      SettingEntry('cobranza.cobrador_edita_cobros'),
      SettingEntry('audit.visible_admin_cobranza'),
    ],
  ),
];

/// Grupos de la tab Pagos.
const kGruposPagos = <SettingGroup>[
  SettingGroup(
    titulo: 'Métodos de pago',
    icono: Icons.payments,
    entradas: [
      // metodo_efectivo queda fijo en ON (lo fuerza el editor del tile).
      SettingEntry('pagos.metodo_efectivo'),
      SettingEntry('pagos.metodo_transferencia'),
      SettingEntry('pagos.deposito_habilitado'),
      SettingEntry('pagos.metodo_tarjeta'),
    ],
  ),
  SettingGroup(
    titulo: 'Dólares',
    icono: Icons.attach_money,
    entradas: [
      SettingEntry(
        'pagos.usd_habilitado',
        hijos: ['pagos.tasa_usd_cordoba'],
      ),
    ],
  ),
];

/// Grupos de la tab Avanzado (solo super_admin). Incluye los settings que
/// consumen recursos del SaaS (foto de comprobante → Storage), las pantallas
/// admin opcionales, y los módulos que el dueño del SaaS habilita por tenant
/// (descuentos, reconexión). La entrada "Campos del historial" se renderiza
/// aparte (es un link a otra pantalla, no un setting) — ver
/// `_GrupoHistorialLink` en el screen.
const kGruposAvanzado = <SettingGroup>[
  SettingGroup(
    titulo: 'Foto de comprobante',
    icono: Icons.photo_camera,
    entradas: [
      SettingEntry(
        'cobranza.comprobante_habilitado',
        hijos: ['cobranza.foto_obligatoria'],
      ),
    ],
  ),
  SettingGroup(
    titulo: 'Pantallas opcionales del admin',
    icono: Icons.dashboard_customize,
    entradas: [
      SettingEntry('cobranza.pantalla_pagos'),
      SettingEntry('cobranza.pantalla_notificaciones'),
    ],
  ),
  SettingGroup(
    titulo: 'Descuentos',
    icono: Icons.percent,
    entradas: [
      SettingEntry(
        'cobranza.descuentos_habilitados',
        hijos: [
          'cobranza.descuento_tipo',
          'cobranza.descuento_max_monto',
          'cobranza.descuento_max_porcentaje',
        ],
      ),
    ],
  ),
  SettingGroup(
    titulo: 'Reconexión',
    icono: Icons.power,
    entradas: [
      SettingEntry(
        'cobranza.cargo_reconexion_habilitado',
        hijos: ['cobranza.monto_reconexion'],
      ),
    ],
  ),
];

/// Devuelve los grupos definidos para una categoría/tab.
List<SettingGroup> gruposDe(String categoria) {
  return switch (categoria) {
    'empresa' => kGruposEmpresa,
    'cobranza' => kGruposCobranza,
    'pagos' => kGruposPagos,
    'avanzado' => kGruposAvanzado,
    _ => const [],
  };
}

/// TODAS las claves reclamadas por algún grupo, en CUALQUIER tab. El catch-all
/// "Otros" la usa para no re-mostrar un setting que ya tiene grupo en otra tab.
/// Caso real: los settings super_admin-only tienen categoría DB 'cobranza' pero
/// se muestran en grupos de la tab 'avanzado'; sin esto, el "Otros" de Cobranza
/// los duplicaría para el super_admin.
Set<String> clavesReclamadasGlobal() {
  final out = <String>{};
  for (final lista in const [
    kGruposEmpresa,
    kGruposCobranza,
    kGruposPagos,
    kGruposAvanzado,
  ]) {
    for (final g in lista) {
      out.addAll(g.todasLasClaves);
    }
  }
  return out;
}
