import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../powersync/db.dart' as ps;

const _maxFotos = 10;
const _bucket = 'fotos-clientes';

class FotoGalleryWidget extends ConsumerStatefulWidget {
  const FotoGalleryWidget({
    super.key,
    required this.clienteId,
    required this.tenantId,
    required this.canEdit,
  });
  final String clienteId;
  final String tenantId;
  final bool canEdit;

  @override
  ConsumerState<FotoGalleryWidget> createState() => _FotoGalleryWidgetState();
}

class _FotoGalleryWidgetState extends ConsumerState<FotoGalleryWidget> {
  late Stream<List<Map<String, dynamic>>> _stream;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(FotoGalleryWidget old) {
    super.didUpdateWidget(old);
    if (old.clienteId != widget.clienteId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      'SELECT id, storage_path, created_at FROM fotos_cliente '
      'WHERE cliente_id = ? ORDER BY created_at ASC',
      parameters: [widget.clienteId],
    );
  }

  Future<void> _pickAndUpload() async {
    if (_uploading) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.split('.').last.toLowerCase();
      final mime = ext == 'jpg' ? 'image/jpeg' : 'image/$ext';
      final storagePath =
          '${widget.tenantId}/${widget.clienteId}/${DateTime.now().millisecondsSinceEpoch}.$ext';

      await Supabase.instance.client.storage
          .from(_bucket)
          .uploadBinary(storagePath, bytes,
              fileOptions: FileOptions(contentType: mime));

      final user = Supabase.instance.client.auth.currentUser;
      final now = DateTime.now().toUtc().toIso8601String();
      final clienteRow = await ps.db.getOptional(
        'SELECT cobrador_id FROM clientes WHERE id = ?',
        [widget.clienteId],
      );
      final cobradorId = clienteRow?['cobrador_id'] as String?;
      await ps.db.execute(
        'INSERT INTO fotos_cliente (id, tenant_id, cliente_id, cobrador_id, storage_path, created_at, created_by) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [const Uuid().v4(), widget.tenantId, widget.clienteId, cobradorId, storagePath, now, user?.id],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto subida')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al subir: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _deleteFoto(String fotoId, String storagePath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar foto'),
        content: const Text('Esta acción no se puede deshacer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ps.db.execute(
          'DELETE FROM fotos_cliente WHERE id = ?', [fotoId]);
      await Supabase.instance.client.storage
          .from(_bucket)
          .remove([storagePath]);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto eliminada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al eliminar: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.photo_library, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text('Fotos',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Text('Error: ${snap.error}');
            }
            final fotos = snap.data!;
            final canAdd = widget.canEdit && fotos.length < _maxFotos;

            if (fotos.isEmpty && !widget.canEdit) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Sin fotos',
                    style: TextStyle(color: scheme.outline)),
              );
            }

            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in fotos)
                  _FotoThumbnail(
                    storagePath: f['storage_path'] as String,
                    canDelete: widget.canEdit,
                    onDelete: () => _deleteFoto(
                        f['id'] as String, f['storage_path'] as String),
                  ),
                if (canAdd)
                  _AddFotoButton(
                    uploading: _uploading,
                    onTap: _pickAndUpload,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FotoThumbnail extends StatefulWidget {
  const _FotoThumbnail({
    required this.storagePath,
    required this.canDelete,
    required this.onDelete,
  });
  final String storagePath;
  final bool canDelete;
  final VoidCallback onDelete;

  @override
  State<_FotoThumbnail> createState() => _FotoThumbnailState();
}

class _FotoThumbnailState extends State<_FotoThumbnail> {
  String? _url;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  @override
  void didUpdateWidget(_FotoThumbnail old) {
    super.didUpdateWidget(old);
    if (old.storagePath != widget.storagePath) _loadUrl();
  }

  Future<void> _loadUrl() async {
    setState(() => _loading = true);
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(widget.storagePath, 86400);
      if (mounted) setState(() { _url = url; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _url = null; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 140.0;

    return MouseRegion(
      cursor: _url != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: _url != null ? () => _showFullScreen(context, _url!) : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _loading
                    ? Container(
                        color: scheme.surfaceContainerHighest,
                        child: const Center(
                            child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))),
                      )
                    : _url != null
                        ? Image.network(
                            _url!,
                            width: size,
                            height: size,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: scheme.surfaceContainerHighest,
                              child: Icon(Icons.broken_image,
                                  color: scheme.outline),
                            ),
                          )
                        : Container(
                            color: scheme.surfaceContainerHighest,
                            child: Icon(Icons.broken_image,
                                color: scheme.outline),
                          ),
              ),
              if (widget.canDelete)
                Positioned(
                  top: 4,
                  right: 4,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onDelete,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: scheme.error,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.close,
                            size: 16, color: scheme.onError),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFullScreen(BuildContext context, String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddFotoButton extends StatelessWidget {
  const _AddFotoButton({required this.uploading, required this.onTap});
  final bool uploading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: uploading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: uploading ? null : onTap,
        child: Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outline, width: 1),
          color: scheme.surfaceContainerHighest,
        ),
        child: uploading
            ? const Center(
                child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo, color: scheme.primary),
                  const SizedBox(height: 4),
                  Text('Agregar',
                      style: TextStyle(fontSize: 11, color: scheme.primary)),
                ],
              ),
      ),
      ),
    );
  }
}
