import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/recibo_layout.dart';

/// Tests del parseo robusto del layout del recibo. `fromRaw` es la fundación
/// del "diseñador de recibo": tiene que sanear datos viejos/corruptos sin
/// perder bloques ni dejar un recibo sin totales.
void main() {
  final catalogoIds = kReciboBloquesCatalogo.map((b) => b.id).toList();

  group('ReciboLayout.fromRaw — defaults y null', () {
    test('null → layout por defecto (todos los bloques, en orden)', () {
      final l = ReciboLayout.fromRaw(null);
      expect(l.map((b) => b.id).toList(), catalogoIds);
      expect(l.every((b) => b.visible), isTrue);
      expect(l.every((b) => b.size == ReciboTextoSize.normal), isTrue);
    });

    test('valor no-lista (corrupto) → por defecto', () {
      expect(ReciboLayout.fromRaw('basura').map((b) => b.id), catalogoIds);
      expect(ReciboLayout.fromRaw(42).length, catalogoIds.length);
    });
  });

  group('ReciboLayout.fromRaw — saneo', () {
    test('descarta ids desconocidos', () {
      final raw = [
        {'id': 'logo', 'visible': true, 'size': 'normal'},
        {'id': 'inexistente', 'visible': true, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      expect(l.any((b) => b.id == 'inexistente'), isFalse);
      // logo queda primero; el resto del catálogo se completa al final.
      expect(l.first.id, 'logo');
      expect(l.map((b) => b.id).toSet(), catalogoIds.toSet());
    });

    test('deduplica ids repetidos (gana el primero)', () {
      final raw = [
        {'id': 'logo', 'visible': false, 'size': 'grande'},
        {'id': 'logo', 'visible': true, 'size': 'chico'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      expect(l.where((b) => b.id == 'logo').length, 1);
      final logo = l.firstWhere((b) => b.id == 'logo');
      expect(logo.visible, isFalse); // el primero
      expect(logo.size, ReciboTextoSize.grande);
    });

    test('completa los bloques faltantes al final, sin perder ninguno', () {
      final raw = [
        {'id': 'totales', 'visible': true, 'size': 'grande'},
        {'id': 'logo', 'visible': true, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      // Los 2 pedidos van primero, en ese orden.
      expect(l[0].id, 'totales');
      expect(l[1].id, 'logo');
      // Ninguno del catálogo se pierde.
      expect(l.map((b) => b.id).toSet(), catalogoIds.toSet());
      expect(l.length, catalogoIds.length);
    });
  });

  group('ReciboLayout.fromRaw — totales no ocultable', () {
    test('totales con visible=false se fuerza a visible=true', () {
      final raw = [
        {'id': 'totales', 'visible': false, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      final totales = l.firstWhere((b) => b.id == 'totales');
      expect(totales.visible, isTrue, reason: 'el dinero no se puede ocultar');
    });

    test('el catálogo marca totales como no ocultable', () {
      expect(reciboBloqueInfo('totales')!.hideable, isFalse);
      // todos los demás sí son ocultables.
      for (final b in kReciboBloquesCatalogo) {
        if (b.id != 'totales') {
          expect(b.hideable, isTrue, reason: '${b.id} debería ser ocultable');
        }
      }
    });
  });

  group('ReciboLayout — round-trip', () {
    test('toJson → fromRaw preserva orden/visibilidad/tamaño', () {
      final original = [
        const ReciboBloque(id: 'empresa', visible: false, size: ReciboTextoSize.grande),
        const ReciboBloque(id: 'logo', visible: true, size: ReciboTextoSize.chico),
      ];
      final json = ReciboLayout.toJson(original);
      final back = ReciboLayout.fromRaw(json);
      expect(back[0].id, 'empresa');
      expect(back[0].visible, isFalse);
      expect(back[0].size, ReciboTextoSize.grande);
      expect(back[1].id, 'logo');
      expect(back[1].size, ReciboTextoSize.chico);
    });
  });
}
