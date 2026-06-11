import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:screenshot/screenshot.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/logo_empresa_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/logo_cache_service.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';
import '../shared/widgets/impersonation_banner.dart';
import 'recibo_mora.dart';
import 'recibo_pdf.dart';
import 'recibo_ticket.dart';
import '../../data/utils/errores.dart';

/// Preview visual del recibo + acción para imprimir.
/// La impresión Bluetooth real se conecta en una iteración siguiente.
class ReciboScreen extends ConsumerStatefulWidget {
  const ReciboScreen({super.key, required this.reciboId, this.grupoCobro});
  final String reciboId;
  final String? grupoCobro;

  @override
  ConsumerState<ReciboScreen> createState() => _ReciboScreenState();
}

class _ReciboScreenState extends ConsumerState<ReciboScreen> {
  late final Stream<List<Map<String, dynamic>>> _reciboStream;

  // Vista preview: si está activa, el body del recibo se constraine al
  // ancho visual de la tira térmica (según `cobranza.formato_recibo_mm`).
  // El recibo se muestra SIEMPRE simulando el ancho real del papel
  // térmico (80mm/58mm). Sin toggle: la vista preview es permanente.

  bool get _esMultiCuota => widget.grupoCobro != null;

  /// Ancho en píxeles para simular la tira térmica.
  /// 80mm ≈ 300px, 58mm ≈ 215px. Cualquier ancho que no sea 80 (incl. el
  /// legacy 57) se trata como angosto.
  double _previewWidthPx(int formatoMm) {
    if (formatoMm != 80) return 215;
    return 300;
  }

  @override
  void initState() {
    super.initState();
    if (_esMultiCuota) {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path, p.grupo_cobro,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE p.grupo_cobro = ? AND p.anulado = 0
         ORDER BY cu.periodo ASC
        ''',
        parameters: [widget.grupoCobro],
      );
    } else {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE r.id = ?
        ''',
        parameters: [widget.reciboId],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    // Logo del recibo: una sola fuente de verdad, la visibilidad del bloque
    // `logo` del layout. Si está visible y hay logo configurado, se cargan los
    // BYTES (no URL): `ReciboTicket` se captura a imagen para imprimir, así que
    // necesita bytes. El provider es offline-first (cache local + fallback red)
    // y reactivo (se refresca si cambia el logo o la visibilidad del bloque).
    final logoVisible =
        settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final logoBytes =
        logoVisible ? ref.watch(logoEmpresaBytesProvider).valueOrNull : null;

    // Rol del usuario: el admin navega DENTRO del AdminShell (con panel
    // lateral); el cobrador a sus rutas full-screen. Sin esto, "home" y "ver
    // detalle del cliente" mandaban al admin a las rutas del cobrador (/ y
    // /clientes/:id), que viven fuera del shell → quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final maxWidth = _previewWidthPx(settings.formatoReciboMm);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recibo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => context.go(esAdmin ? '/admin' : '/'),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _reciboStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              titulo: 'Error al cargar el recibo',
            );
          }
          // M11: sin initialData, el primer frame muestra carga en vez de
          // flashear "Recibo no encontrado" antes de que llegue la data real.
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long,
              titulo: 'Recibo no encontrado',
            );
          }
          final r = rows.first;
          final esMulti = _esMultiCuota && rows.length > 1;

          // Detalle de mora del contrato para el bloque `mora`. Mismo cálculo
          // que el path de impresión: se excluye(n) la(s) cuota(s) cobrada(s).
          // Cuota manual (contrato_id null) → mora vacía.
          final moraRows = _moraParaPreview(rows, esMulti, settings);

          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const ImpersonationBanner(), // #9a
                  // Preview = EXACTAMENTE el widget que se imprime (WYSIWYG).
                  // Se construye al ancho real del papel (dots) y se escala a la
                  // tira de pantalla con FittedBox → lo que ve el cobrador es
                  // lo que sale por la térmica.
                  Center(
                    child: FittedBox(
                      // contain (no scaleDown): escala para LLENAR el ancho de
                      // la preview (arriba o abajo), no solo achicar — sino en
                      // pantalla ancha el ticket se ve diminuto.
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      child: ReciboTicket(
                        row: esMulti ? null : r,
                        rows: esMulti ? rows : null,
                        settings: settings,
                        logoBytes: logoBytes,
                        moraRows: moraRows,
                      ),
                    ),
                  ),
                  if (r['foto_comprobante_path'] != null) ...[
                    const SizedBox(height: 16),
                    Text('Comprobante adjunto',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    FotoComprobanteView(
                        path: r['foto_comprobante_path'] as String?),
                  ],
                  const SizedBox(height: 24),
                  _AccionesImpresion(
                    reciboId: widget.reciboId,
                    recibo: r,
                    settings: settings,
                    multiRows: esMulti ? rows : null,
                  ),
                  const SizedBox(height: 16),
                  _PostCobroActions(clienteId: r['cliente_id'] as String?),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Mora del contrato para la PREVIEW (vía `moraContratoProvider`, reactivo).
  /// Single: excluye la cuota cobrada. Multi: excluye TODAS las del grupo.
  /// Cuota manual (sin contrato) → vacío. El path de impresión calcula lo mismo
  /// con `fetchMoraContrato` (no puede usar `ref` adentro del service).
  List<Map<String, dynamic>> _moraParaPreview(
      List<Map<String, dynamic>> rows, bool esMulti, AppSettings settings) {
    final contratoId = rows.first['contrato_id'] as String?;
    if (contratoId == null) return const [];
    final cobradas = (esMulti ? rows.map((r) => r['cuota_id']) : [rows.first['cuota_id']])
        .whereType<Object>()
        .toSet();
    final todas = ref
            .watch(moraContratoProvider((
              contratoId: contratoId,
              diasGracia: settings.diasGracia,
            )))
            .valueOrNull ??
        const [];
    return todas.where((m) => !cobradas.contains(m['cuota_id'])).toList();
  }
}

class _AccionesImpresion extends ConsumerStatefulWidget {
  const _AccionesImpresion({
    required this.reciboId,
    required this.recibo,
    required this.settings,
    this.multiRows,
  });
  final String reciboId;
  final Map<String, dynamic> recibo;
  final AppSettings settings;

  /// Si está presente, el recibo es un cobro múltiple (todas las filas del
  /// grupo). Caso contrario, recibo individual.
  final List<Map<String, dynamic>>? multiRows;

  @override
  ConsumerState<_AccionesImpresion> createState() => _AccionesImpresionState();
}

class _AccionesImpresionState extends ConsumerState<_AccionesImpresion> {
  bool _imprimiendo = false;
  bool _descargandoPdf = false;
  bool _imprimiendoSistema = false;

  /// Construye los bytes del PDF del recibo + un filename legible. Lo COMPARTEN
  /// "Descargar PDF" (web) e "Imprimir en impresora del sistema" (desktop), así
  /// la lógica de logo/mora no se duplica.
  Future<({Uint8List bytes, String filename})> _generarReciboPdf() async {
    // Logo del PDF (best-effort): bytes del provider offline-first (cache +
    // fallback red). Si no hay, el PDF se genera sin logo — no rompemos por un
    // error de red en una imagen. Solo si el bloque `logo` está visible.
    final logoVisible = widget.settings.reciboLayout
        .any((b) => b.id == 'logo' && b.visible);
    final logoBytes = logoVisible
        ? ref.read(logoEmpresaBytesProvider).valueOrNull
        : null;

    // Detalle de mora del contrato para el bloque `mora` del PDF. Single:
    // excluir la cuota cobrada. Multi: excluir TODAS las del grupo. Cuota
    // manual (contrato_id null) → mora vacía.
    final multiRows = widget.multiRows;
    final contratoId = (multiRows != null ? multiRows.first : widget.recibo)[
        'contrato_id'] as String?;
    final excluir = (multiRows != null
            ? multiRows.map((r) => r['cuota_id'])
            : [widget.recibo['cuota_id']])
        .whereType<Object>()
        .toSet();
    final moraRows = contratoId == null
        ? const <Map<String, dynamic>>[]
        : (await fetchMoraContrato(contratoId, widget.settings.diasGracia))
            .where((m) => !excluir.contains(m['cuota_id']))
            .toList();

    final doc = await _construirReciboDoc(
        logoBytes: logoBytes, moraRows: moraRows);
    final bytes = await doc.save();
    final numero =
        (widget.recibo['numero_completo'] as String?) ?? widget.reciboId;
    final filename =
        'recibo_${numero.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.pdf';
    return (bytes: bytes, filename: filename);
  }

  Future<void> _descargarPdf() async {
    setState(() => _descargandoPdf = true);
    try {
      final pdf = await _generarReciboPdf();
      await Printing.sharePdf(bytes: pdf.bytes, filename: pdf.filename);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF generado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al generar PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _descargandoPdf = false);
    }
  }

  /// Imprime el recibo en una impresora del SISTEMA (USB/cableada/red) vía el
  /// diálogo nativo de Windows. Pensado para admins en PC con impresora térmica
  /// USB (alternativa a la Bluetooth de campo). El PDF usa el mismo ancho de
  /// rollo (58/80mm) configurado, así que sirve para la térmica USB.
  Future<void> _imprimirSistema() async {
    setState(() => _imprimiendoSistema = true);
    try {
      final pdf = await _generarReciboPdf();
      await Printing.layoutPdf(
        onLayout: (_) async => pdf.bytes,
        name: pdf.filename,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al imprimir: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendoSistema = false);
    }
  }

  /// Construye el `Document` PDF del recibo (single o multi según
  /// `widget.multiRows`). Lo COMPARTEN el path de "Descargar PDF" (logo de red)
  /// y el de impresión térmica (logo del cache local), para no duplicar la
  /// construcción. El call-site provee `logoBytes` (de su fuente) y `moraRows`
  /// (ya filtrado).
  Future<pw.Document> _construirReciboDoc({
    required Uint8List? logoBytes,
    required List<Map<String, dynamic>> moraRows,
  }) {
    final multiRows = widget.multiRows;
    return multiRows != null
        ? buildMultiReciboPdf(
            rows: multiRows,
            settings: widget.settings,
            logoBytes: logoBytes,
            moraRows: moraRows)
        : buildReciboPdf(
            row: widget.recibo,
            settings: widget.settings,
            logoBytes: logoBytes,
            moraRows: moraRows);
  }

  /// Calcula la mora del contrato para el bloque `mora` (mismo cálculo que
  /// pantalla/PDF). Single: excluir la cuota cobrada. Multi: excluir TODAS las
  /// del grupo. Cuota manual (contrato_id null) → mora vacía.
  Future<List<Map<String, dynamic>>> _moraParaImpresion() async {
    final multiRows = widget.multiRows;
    final contratoId = (multiRows != null ? multiRows.first : widget.recibo)[
        'contrato_id'] as String?;
    final excluir = (multiRows != null
            ? multiRows.map((r) => r['cuota_id'])
            : [widget.recibo['cuota_id']])
        .whereType<Object>()
        .toSet();
    return contratoId == null
        ? const <Map<String, dynamic>>[]
        : (await fetchMoraContrato(contratoId, widget.settings.diasGracia))
            .where((m) => !excluir.contains(m['cuota_id']))
            .toList();
  }

  /// CAPTURA el widget `ReciboTicket` a PNG (al ancho exacto del papel en
  /// dots). Lo COMPARTEN el path de impresión real y el de diagnóstico, así lo
  /// que se diagnostica es BYTE-POR-BYTE lo que se imprime. Devuelve null y
  /// muestra un snackbar si la captura falla.
  Future<Uint8List?> _capturarReciboPng() async {
    final moraRows = await _moraParaImpresion();

    // Logo para la térmica: se lee del CACHE LOCAL (sin red — la impresión es
    // 100% offline). Solo si el bloque `logo` está visible en el layout
    // (paridad con pantalla/PDF). Si nunca se cacheó queda null.
    final logoVisible =
        widget.settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final tenantId = ref.read(tenantIdProvider);
    Uint8List? logoBytes;
    if (logoVisible && tenantId != null) {
      logoBytes = await LogoCacheService().leerLogoCacheado(tenantId);
    }

    // WYSIWYG: se CAPTURA a imagen el MISMO widget `ReciboTicket` que muestra
    // la preview (lo renderiza Skia), y se manda como raster ESC/POS. Así las
    // tildes salen perfectas en CUALQUIER impresora, 100% OFFLINE (sin PDFium
    // ni fuentes embebidas). El layout/orden/mora/multi ya viven en el widget.
    final anchoDots = reciboAnchoDots(widget.settings.formatoReciboMm);
    final multiCuota = widget.multiRows != null;
    final ticket = ReciboTicket(
      row: multiCuota ? null : widget.recibo,
      rows: multiCuota ? widget.multiRows : null,
      settings: widget.settings,
      logoBytes: logoBytes,
      moraRows: moraRows,
    );
    final ticketCapturable = Directionality(
      textDirection: TextDirection.ltr,
      // Container BLANCO que cubre TODO el targetSize (anchoDots × 5000): así
      // NO queda ninguna zona no-blanca en la captura. El ticket va arriba; el
      // blanco sobrante lo recorta imprimirImagen.
      child: Container(
        width: anchoDots.toDouble(),
        height: 5000,
        color: Colors.white,
        alignment: Alignment.topCenter,
        child: Material(type: MaterialType.transparency, child: ticket),
      ),
    );

    try {
      return await ScreenshotController().captureFromWidget(
        ticketCapturable,
        pixelRatio: 1.0,
        targetSize: Size(anchoDots.toDouble(), 5000),
        // delay para que las imágenes (logo) terminen de pintar antes del
        // snapshot — si no, el logo puede salir en blanco.
        delay: const Duration(milliseconds: 80),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo generar el recibo: $e')),
        );
      }
      return null;
    }
  }

  Future<void> _imprimir() async {
    final favState = ref.read(impresoraFavoritaProvider);
    // Si todavía no se leyó SharedPreferences, esperar y reintentar.
    if (!favState.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cargando preferencias…')),
      );
      return;
    }
    final fav = favState.value;
    if (fav == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No tenés impresora configurada'),
          action: SnackBarAction(
            label: 'Configurar',
            onPressed: () => context.push('/perfil/impresora'),
          ),
        ),
      );
      return;
    }

    setState(() => _imprimiendo = true);
    try {
      final service = ref.read(impresoraServiceProvider);

      final pngBytes = await _capturarReciboPng();
      if (pngBytes == null) return;

      final ok = await service.imprimirImagen(
        macImpresora: fav.mac,
        pngBytes: pngBytes,
        anchoMm: widget.settings.formatoReciboMm,
      );

      if (!mounted) return;
      if (ok) {
        // Actualizar BD local: impreso_en + formato. `impreso_en` se conserva
        // porque el guard del correlativo lo usa; el CONTEO de reimpresiones se
        // quitó (no se muestra ni se incrementa más).
        await ps.db.execute(
          '''
          UPDATE recibos
             SET impreso_en = ?,
                 ultimo_formato_mm = ?,
                 ocurrido_en = ?
           WHERE id = ?
          ''',
          [
            DateTime.now().toIso8601String(),
            widget.settings.formatoReciboMm,
            DateTime.now().toUtc().toIso8601String(),
            widget.reciboId,
          ],
        );
        // C7: re-chequear tras el await — el execute pudo resolver con la
        // pantalla ya desmontada (context muerto para el SnackBar).
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recibo enviado a impresora')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo conectar a la impresora')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fav = ref.watch(impresoraFavoritaProvider).valueOrNull;
    final puedeImprimir = !kIsWeb;
    // Desktop (PC): habilitar impresión por impresora del sistema (USB/cableada
    // /red), además de la Bluetooth. Pensado para admins en Windows.
    final esDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    return Column(
      children: [
        // Impresión Bluetooth térmica: solo mobile. En web se usa el PDF.
        if (!kIsWeb)
          FilledButton.icon(
            icon: _imprimiendo
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print),
            label: Text(_imprimiendo
                ? 'Enviando...'
                : 'Imprimir ${widget.settings.formatoReciboMm}mm'),
            onPressed: _imprimiendo || !puedeImprimir ? null : _imprimir,
          ),
        // Impresión por impresora del sistema (cableada/USB/red) — solo desktop.
        if (esDesktop) ...[
          const SizedBox(height: 8),
          Tooltip(
            message:
                'Abre el diálogo de Windows. Usa el ancho de rollo ${widget.settings.formatoReciboMm}mm: '
                'pensado para impresora térmica USB/cableada.',
            child: FilledButton.tonalIcon(
              icon: _imprimiendoSistema
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.print_outlined),
              label: Text(_imprimiendoSistema
                  ? 'Abriendo impresora...'
                  : 'Imprimir en impresora del sistema'),
              onPressed: _imprimiendoSistema ? null : _imprimirSistema,
            ),
          ),
        ],
        // PDF download — solo visible en web. En mobile usan la impresora
        // Bluetooth térmica, así que el PDF no aporta nada.
        if (kIsWeb) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: _descargandoPdf
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf),
            label: Text(_descargandoPdf
                ? 'Generando PDF...'
                : 'Descargar PDF ${widget.settings.formatoReciboMm}mm'),
            onPressed: _descargandoPdf ? null : _descargarPdf,
          ),
        ],
        const SizedBox(height: 8),
        if (!kIsWeb)
          OutlinedButton.icon(
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(fav == null
                ? 'Configurar impresora'
                : 'Cambiar impresora (${fav.nombre})'),
            onPressed: () => context.push('/perfil/impresora'),
          ),
        const SizedBox(height: 16),
        Text(
          'El recibo queda guardado y sincronizado aunque la impresora '
          'falle. Podés reintentar imprimir cuando quieras.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _PostCobroActions extends ConsumerWidget {
  const _PostCobroActions({required this.clienteId});
  final String? clienteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = clienteId;
    if (id == null) return const SizedBox.shrink();
    // Ruta según rol: el admin va al detalle dentro del AdminShell (con panel
    // lateral). El cobrador a /clientes/:id (full-screen). Antes era fijo a
    // /clientes/:id y el admin quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final clientePath = esAdmin ? '/admin/clientes/$id' : '/clientes/$id';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.person),
          label: const Text('Ver detalle del cliente'),
          onPressed: () => context.go(clientePath),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
