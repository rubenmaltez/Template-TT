import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show SyncStatus;

import '../../../data/providers/sync_status_provider.dart';

/// Banner persistente que aparece cuando PowerSync está desconectado.
/// Pensado para envolver el body de los shells (cobrador y admin).
///
/// **Debounce de 3s al aparecer**: el banner NO se muestra inmediato al
/// detectar `connected == false`. Espera 3s consecutivos offline antes de
/// aparecer.
///
/// **Por qué**: durante el handshake inicial de PowerSync (post-login,
/// post-reconnect, post-cambio de identidad), `status.connected` arranca
/// en `false` por ~1-2s antes de flippar a `true`. Sin debounce, el
/// banner aparecía y desaparecía causando un flash de "Sin conexión"
/// engañoso al user — la app SÍ estaba conectada pero el sync se estaba
/// estableciendo. Con debounce, solo aparece si la desconexión es real
/// (≥3s consecutivos).
///
/// **Asimetría intencional**: al reconectar, el banner desaparece
/// **inmediato** (no hay debounce de salida — queremos quitar el ruido
/// visual rápido). El trade-off es que un flicker rápido (`false → true
/// → false` en <3s) silencia el banner — eso oculta "red inestable" como
/// señal. Si en el futuro queremos distinguir "red inestable" de "todo
/// bien", agregar un indicador sutil aparte del banner.
///
/// **Patrón**: usa `ref.listen` en lugar de `ref.watch` + setState. El
/// listener solo dispara en CAMBIOS del provider, no en cada rebuild —
/// evita races sutiles entre estado del widget y stream del provider.
/// El estado inicial al mountear lo manejamos en `initState` con un
/// `ref.read` post-frame.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key, required this.child});
  final Widget child;

  static const _debounce = Duration(seconds: 3);

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  Timer? _showTimer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    // Estado inicial: si la app arranca ya con PowerSync desconectado,
    // schedule el handler. `ref.read` no se puede llamar dentro de
    // initState directo — lo hacemos post-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final offline =
          ref.read(syncStatusProvider).valueOrNull?.connected == false;
      if (offline) _onStatusChange(true);
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    super.dispose();
  }

  /// Reacciona a un cambio del estado de conexión. Idempotente: llamarlo
  /// repetido con el mismo `offline` no hace nada extra.
  ///
  /// - `offline=true` con timer pending o banner visible → skip (ya
  ///   está en proceso o mostrado).
  /// - `offline=true` desde estado limpio → schedule timer 3s.
  /// - `offline=false` con timer pending → cancela (silencia handshake).
  /// - `offline=false` con banner visible → oculta inmediato.
  /// - `offline=false` desde estado limpio → no-op.
  void _onStatusChange(bool offline) {
    if (offline) {
      if (_showTimer != null || _show) return;
      _showTimer = Timer(OfflineBanner._debounce, () {
        _showTimer = null;
        if (mounted) setState(() => _show = true);
      });
    } else {
      _showTimer?.cancel();
      _showTimer = null;
      if (_show) setState(() => _show = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen reacciona SOLO a cambios del stream, sin causar rebuild
    // adicional ni necesitar tracking manual del último valor. El estado
    // inicial lo manejamos en initState (ref.listen no dispara en mount).
    ref.listen<AsyncValue<SyncStatus?>>(syncStatusProvider, (_, next) {
      final offline = next.valueOrNull?.connected == false;
      _onStatusChange(offline);
    });

    return Column(
      children: [
        if (_show) const _Banner(),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sin conexión. Los cambios se guardan localmente y se '
                  'sincronizarán al volver la red.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
