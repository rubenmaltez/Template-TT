import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/foto_comprobante_provider.dart';

/// Renderiza una foto del comprobante manejando ambos casos del path:
///   - `local://*` → carga el archivo desde disco
///   - cualquier otro string → asume path en Storage y obtiene URL firmada
///
/// Si no se puede mostrar, devuelve null (no ocupa espacio).
class FotoComprobanteView extends ConsumerStatefulWidget {
  const FotoComprobanteView({
    super.key,
    required this.path,
    this.height = 200,
    this.borderRadius = 12,
  });

  final String? path;
  final double height;
  final double borderRadius;

  @override
  ConsumerState<FotoComprobanteView> createState() =>
      _FotoComprobanteViewState();
}

class _FotoComprobanteViewState extends ConsumerState<FotoComprobanteView> {
  File? _local;
  String? _urlFirmada;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _resolver();
  }

  @override
  void didUpdateWidget(covariant FotoComprobanteView old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path) _resolver();
  }

  Future<void> _resolver() async {
    if (widget.path == null) {
      setState(() {
        _local = null;
        _urlFirmada = null;
        _cargando = false;
      });
      return;
    }
    setState(() => _cargando = true);
    final service = ref.read(fotoComprobanteServiceProvider);
    if (widget.path!.startsWith('local://')) {
      final f = await service.archivoLocal(widget.path!);
      if (mounted) setState(() {
        _local = f;
        _urlFirmada = null;
        _cargando = false;
      });
    } else {
      final url = await service.urlFirmada(widget.path!);
      if (mounted) setState(() {
        _local = null;
        _urlFirmada = url;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.path == null) return const SizedBox.shrink();
    if (_cargando) {
      return SizedBox(
        height: widget.height,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final radius = BorderRadius.circular(widget.borderRadius);
    final pendiente = widget.path!.startsWith('local://');

    Widget img;
    if (_local != null) {
      img = Image.file(_local!, height: widget.height, fit: BoxFit.cover);
    } else if (_urlFirmada != null) {
      img = Image.network(_urlFirmada!, height: widget.height, fit: BoxFit.cover);
    } else {
      // Path remoto que no resolvió URL (sin internet o permiso).
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: const Center(
          child: Icon(Icons.cloud_off, size: 32),
        ),
      );
    }

    return Stack(
      children: [
        ClipRRect(borderRadius: radius, child: img),
        if (pendiente)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_upload,
                      size: 14,
                      color: Theme.of(context).colorScheme.onTertiary),
                  const SizedBox(width: 4),
                  Text(
                    'Pendiente de subir',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
