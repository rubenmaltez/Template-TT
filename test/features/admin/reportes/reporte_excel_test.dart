import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:isp_billing/features/admin/reportes/excel/reporte_excel.dart';

String? _texto(Sheet sheet, int col, int row) {
  final v = sheet
      .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
      .value;
  return v?.toString();
}

void main() {
  setUpAll(() async {
    // Locale data de es_NI para Fmt.fechaCorta ("Generado: dd/MM/yyyy").
    await initializeDateFormatting('es_NI', null);
  });

  group('construirExcelBytes', () {
    test('sin branding: headers en fila 0 y datos desde fila 1 (layout '
        'histórico, lo consume quien no pasa empresaNombre)', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Cobros',
        headers: ['Cliente', 'Monto'],
        filas: [
          ['Juan', 100.5],
          ['Ana', 3],
        ],
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Cobros'];
      expect(_texto(sheet, 0, 0), 'Cliente');
      expect(_texto(sheet, 1, 0), 'Monto');
      expect(_texto(sheet, 0, 1), 'Juan');
      expect(_texto(sheet, 1, 1), '100.5');
      expect(_texto(sheet, 1, 2), '3');
    });

    test('con branding: empresa/título/período arriba, fila en blanco y '
        'tabla desde la fila 5', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Cobros',
        headers: ['Cliente', 'Monto'],
        filas: [
          ['Juan', 100.5],
        ],
        empresaNombre: 'Telecable Demo',
        titulo: 'Reporte de cobros',
        periodo: '01/06/2026 – 12/06/2026',
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Cobros'];
      expect(_texto(sheet, 0, 0), 'Telecable Demo');
      expect(_texto(sheet, 0, 1), 'Reporte de cobros');
      expect(_texto(sheet, 0, 2), contains('Período: 01/06/2026'));
      expect(_texto(sheet, 0, 2), contains('Generado:'));
      // Fila 3 en blanco.
      expect(_texto(sheet, 0, 3), isNull);
      // Tabla: headers en fila 4, datos en fila 5.
      expect(_texto(sheet, 0, 4), 'Cliente');
      expect(_texto(sheet, 1, 4), 'Monto');
      expect(_texto(sheet, 0, 5), 'Juan');
      expect(_texto(sheet, 1, 5), '100.5');
      // Las filas de branding quedan mergeadas a lo ancho de la tabla.
      expect(sheet.spannedItems, contains('A1:B1'));
    });

    test('branding sin período usa solo la fecha de generación', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Clientes',
        headers: ['Nombre'],
        filas: [
          ['Ana'],
        ],
        empresaNombre: 'Telecable Demo',
        titulo: 'Listado de clientes',
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Clientes'];
      expect(_texto(sheet, 0, 2), startsWith('Generado:'));
      // Con una sola columna no hay merge (no hay ancho que cubrir).
      expect(sheet.spannedItems, isEmpty);
      expect(_texto(sheet, 0, 4), 'Nombre');
      expect(_texto(sheet, 0, 5), 'Ana');
    });
  });
}
