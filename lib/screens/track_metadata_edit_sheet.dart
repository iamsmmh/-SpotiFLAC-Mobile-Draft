part of 'track_metadata_screen.dart';

class _AutoFillPreview {
  final Map<String, String> values;
  final String sourceName;
  final String? coverUrl;
  final String? coverPath;
  final String? coverTempDir;
  final ({int width, int height, int bytes})? coverDetails;

  const _AutoFillPreview({
    required this.values,
    required this.sourceName,
    this.coverUrl,
    this.coverPath,
    this.coverTempDir,
    this.coverDetails,
  });
}

class _MetadataCandidateArtwork extends StatefulWidget {
  final String? coverUrl;

  const _MetadataCandidateArtwork({required this.coverUrl});

  @override
  State<_MetadataCandidateArtwork> createState() =>
      _MetadataCandidateArtworkState();
}

class _MetadataCandidateArtworkState extends State<_MetadataCandidateArtwork> {
  String? _tempDir;
  String? _coverPath;
  ({int width, int height, int bytes})? _details;

  @override
  void initState() {
    super.initState();
    if (widget.coverUrl?.isNotEmpty == true) {
      unawaited(_loadCover());
    }
  }

  Future<void> _loadCover() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'metadata_candidate_cover_',
    );
    final path = '${tempDir.path}${Platform.pathSeparator}cover.jpg';
    try {
      final result = await PlatformBridge.downloadCoverToFile(
        widget.coverUrl!,
        path,
      );
      if (result['error'] != null || !await File(path).exists()) {
        await tempDir.delete(recursive: true);
        return;
      }
      final dimensions = await FFmpegService.probeImageDimensions(path);
      final bytes = await File(path).length();
      if (!mounted) {
        await tempDir.delete(recursive: true);
        return;
      }
      setState(() {
        _tempDir = tempDir.path;
        _coverPath = path;
        if (dimensions != null) {
          _details = (
            width: dimensions.width,
            height: dimensions.height,
            bytes: bytes,
          );
        }
      });
    } catch (_) {
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        _log.d('best-effort step failed: $e');
      }
    }
  }

  @override
  void dispose() {
    final tempDir = _tempDir;
    if (tempDir != null) {
      unawaited(() async {
        try {
          final directory = Directory(tempDir);
          if (await directory.exists()) await directory.delete(recursive: true);
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final coverUrl = widget.coverUrl;
    final details = _details;
    final image = _coverPath != null
        ? Image.file(
            File(_coverPath!),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
            cacheHeight: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
            filterQuality: FilterQuality.low,
          )
        : coverUrl != null
        ? CachedCoverImage(
            imageUrl: coverUrl,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
          )
        : Container(
            width: 56,
            height: 56,
            color: colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.music_note),
          );

    return SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: image),
          if (details != null) ...[
            const SizedBox(height: 3),
            Text(
              '${details.width}×${details.height} · '
              '${(details.bytes / 1024).toStringAsFixed(1)} KB',
              maxLines: 2,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontSize: 9,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EditMetadataSheet extends StatefulWidget {
  static const _onlineCoverSentinel = '__online_cover__';
  final ColorScheme colorScheme;
  final Map<String, String> initialValues;
  final String filePath;
  final String? sourceTrackId;
  final int durationMs;
  final String artistTagMode;

  const _EditMetadataSheet({
    required this.colorScheme,
    required this.initialValues,
    required this.filePath,
    this.sourceTrackId,
    required this.durationMs,
    required this.artistTagMode,
  });

  @override
  State<_EditMetadataSheet> createState() => _EditMetadataSheetState();
}

class _EditMetadataSheetState extends State<_EditMetadataSheet> {
  static const _coverResizeDimensions = <int>[500, 1000, 1500, 2000, 3000];
  static final RegExp _metadataCollapsePattern = RegExp(r'[^a-z0-9]+');
  static final RegExp _metadataWhitespacePattern = RegExp(r'\s+');
  static final RegExp _spotifyTrackIdPattern = RegExp(r'^[A-Za-z0-9]{22}$');
  static final RegExp _deezerTrackIdPattern = RegExp(r'^\d+$');
  static final RegExp _isrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');

  bool _saving = false;
  bool _showAdvanced = false;
  bool _showAutoFill = false;
  bool _fetching = false;
  String? _selectedCoverPath;
  String? _selectedCoverTempDir;
  String? _selectedCoverName;
  String? _currentCoverPath;
  String? _currentCoverTempDir;
  bool _loadingCurrentCover = false;
  int? _coverMaxDimension;
  final Map<String, ({int width, int height, int bytes})> _coverDetails = {};
  final Set<String> _coverDetailLoads = {};
  String? _selectedMetadataProviderId;
  _AutoFillPreview? _autoFillPreview;
  final GlobalKey<ScaffoldMessengerState> _sheetMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  final Set<String> _autoFillFields = {};

  List<Extension> _orderedMetadataProviders(ExtensionState state) {
    final providersById = <String, Extension>{
      for (final extension in state.extensions)
        if (extension.enabled && extension.hasMetadataProvider)
          extension.id: extension,
    };
    final ordered = <Extension>[];
    for (final id in state.metadataProviderPriority) {
      final extension = providersById.remove(id);
      if (extension != null) ordered.add(extension);
    }
    final remaining = providersById.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return [...ordered, ...remaining];
  }

  String _metadataProviderName(String? providerId) {
    final normalized = providerId?.trim() ?? '';
    if (normalized.isEmpty) {
      return context.l10n.editMetadataAutoFillSourceAutomatic;
    }
    final extensionState = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(extensionProvider);
    return extensionState.extensions
            .where((extension) => extension.id == normalized)
            .firstOrNull
            ?.displayName ??
        normalized;
  }

  Future<void> _showMetadataProviderPicker(List<Extension> providers) async {
    FocusScope.of(context).unfocus();
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        final currentId =
            providers.any(
              (extension) => extension.id == _selectedMetadataProviderId,
            )
            ? _selectedMetadataProviderId!
            : '';
        final options = <({String id, String name, IconData icon})>[
          (
            id: '',
            name: sheetContext.l10n.editMetadataAutoFillSourceAutomatic,
            icon: Icons.auto_awesome_outlined,
          ),
          for (final extension in providers)
            (
              id: extension.id,
              name: extension.displayName,
              icon: Icons.extension_outlined,
            ),
        ];

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    sheetContext.l10n.editMetadataAutoFillSource,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SettingsGroup(
                      children: [
                        for (var index = 0; index < options.length; index++)
                          _metadataProviderOption(
                            context: sheetContext,
                            id: options[index].id,
                            name: options[index].name,
                            icon: options[index].icon,
                            selected: options[index].id == currentId,
                            showDivider: index != options.length - 1,
                            cs: cs,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || selectedId == null) return;
    setState(() {
      _selectedMetadataProviderId = selectedId.isEmpty ? null : selectedId;
      _invalidateAutoFillPreview();
    });
  }

  Future<void> _showCoverResolutionPicker() async {
    FocusScope.of(context).unfocus();
    final currentValue = _coverMaxDimension ?? 0;
    final selectedValue = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        final options = <({int value, String label})>[
          (
            value: 0,
            label: _originalCoverResolutionLabel(
              sheetContext.l10n.trackConvertOriginal,
            ),
          ),
          for (final dimension in _coverResizeDimensions)
            (value: dimension, label: '$dimension px'),
        ];
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    sheetContext.l10n.trackCoverResolution,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SettingsGroup(
                      children: [
                        for (var index = 0; index < options.length; index++)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 4,
                                ),
                                leading: Icon(
                                  options[index].value == 0
                                      ? Icons.photo_size_select_actual_outlined
                                      : Icons.photo_size_select_large_outlined,
                                  color: options[index].value == currentValue
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                                title: Text(options[index].label),
                                selected: options[index].value == currentValue,
                                selectedColor: cs.primary,
                                trailing: options[index].value == currentValue
                                    ? const Icon(Icons.check_rounded)
                                    : null,
                                onTap: () => Navigator.pop(
                                  sheetContext,
                                  options[index].value,
                                ),
                              ),
                              if (index != options.length - 1)
                                Divider(
                                  height: 1,
                                  indent: 60,
                                  endIndent: 20,
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || selectedValue == null) return;
    setState(() {
      _coverMaxDimension = selectedValue == 0 ? null : selectedValue;
    });
  }

  Widget _metadataProviderOption({
    required BuildContext context,
    required String id,
    required String name,
    required IconData icon,
    required bool selected,
    required bool showDivider,
    required ColorScheme cs,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          leading: Icon(
            icon,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
          selected: selected,
          selectedColor: cs.primary,
          trailing: selected ? const Icon(Icons.check_rounded) : null,
          onTap: () => Navigator.pop(context, id),
        ),
        if (showDivider)
          Divider(
            height: 1,
            indent: 60,
            endIndent: 20,
            color: cs.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }

  void _invalidateAutoFillPreview() {
    final preview = _autoFillPreview;
    _autoFillPreview = null;
    final coverPath = preview?.coverPath;
    if (coverPath != null) {
      _coverDetails.remove(coverPath);
      _coverDetailLoads.remove(coverPath);
    }
    final tempDir = preview?.coverTempDir;
    if (tempDir != null && tempDir.isNotEmpty) {
      unawaited(_deleteTempDirectory(tempDir));
    }
  }

  Future<void> _deleteTempDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
  }

  void _showSheetSnackBar(String message) {
    final snackBar = SnackBar(content: Text(message));
    final messenger = _sheetMessengerKey.currentState;
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(snackBar);
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(snackBar);
  }

  static const _fieldDefs = <String, String>{
    'title': 'title',
    'artist': 'artist',
    'album': 'album',
    'album_artist': 'album_artist',
    'date': 'date',
    'track_number': 'track_number',
    'total_tracks': 'total_tracks',
    'disc_number': 'disc_number',
    'total_discs': 'total_discs',
    'genre': 'genre',
    'isrc': 'isrc',
    'lyrics': 'lyrics',
    'label': 'label',
    'copyright': 'copyright',
    'composer': 'composer',
    'comment': 'comment',
    'album_type': 'album_type',
    'explicit': 'explicit',
    'upc': 'upc',
    'cover': 'cover',
  };

  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _albumCtrl;
  late final TextEditingController _albumArtistCtrl;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _trackNumCtrl;
  late final TextEditingController _trackTotalCtrl;
  late final TextEditingController _discNumCtrl;
  late final TextEditingController _discTotalCtrl;
  late final TextEditingController _genreCtrl;
  late final TextEditingController _isrcCtrl;
  late final TextEditingController _lyricsCtrl;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _copyrightCtrl;
  late final TextEditingController _composerCtrl;
  late final TextEditingController _commentCtrl;
  late final TextEditingController _albumTypeCtrl;
  late final TextEditingController _upcCtrl;
  bool _explicit = false;
  bool _fetchingMusicBrainz = false;

  bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

  String _originalCoverResolutionLabel(String originalLabel) {
    final sourcePath = _selectedCoverPath ?? _currentCoverPath;
    final details = sourcePath == null ? null : _coverDetails[sourcePath];
    if (details == null) return originalLabel;
    return '$originalLabel · ${details.width} × ${details.height} px · '
        '${_formatCoverBytes(details.bytes)}';
  }

  String _formatCoverBytes(int bytes) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  Future<({int width, int height, int bytes})?> _readCoverDetails(
    String path,
  ) async {
    final dimensions = await FFmpegService.probeImageDimensions(path);
    if (dimensions == null) return null;
    try {
      final bytes = await File(path).length();
      return (width: dimensions.width, height: dimensions.height, bytes: bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadCoverDetails(String path) async {
    if (_coverDetails.containsKey(path) || !_coverDetailLoads.add(path)) {
      return;
    }
    final details = await _readCoverDetails(path);
    if (!mounted) return;
    setState(() {
      _coverDetailLoads.remove(path);
      final isActivePath =
          path == _currentCoverPath || path == _selectedCoverPath;
      if (isActivePath && details != null) {
        _coverDetails[path] = details;
      }
    });
  }

  Future<
    ({
      String path,
      String tempDir,
      ({int width, int height, int bytes})? details,
    })?
  >
  _downloadAutoFillCoverPreview(String coverUrl) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'autofill_cover_preview_',
    );
    final coverPath = '${tempDir.path}${Platform.pathSeparator}cover.jpg';
    try {
      await PlatformBridge.downloadCoverToFile(coverUrl, coverPath);
      final file = File(coverPath);
      if (!await file.exists() || await file.length() <= 0) {
        await tempDir.delete(recursive: true);
        return null;
      }
      return (
        path: coverPath,
        tempDir: tempDir.path,
        details: await _readCoverDetails(coverPath),
      );
    } catch (_) {
      await _deleteTempDirectory(tempDir.path);
      return null;
    }
  }

  String _resolveImageExtension(String? ext, Uint8List? bytes) {
    final normalized = (ext ?? '').toLowerCase();
    if (normalized == 'png' ||
        normalized == 'jpg' ||
        normalized == 'jpeg' ||
        normalized == 'webp') {
      return normalized == 'jpeg' ? 'jpg' : normalized;
    }
    if (bytes != null && bytes.length >= 8) {
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return 'png';
      }
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        return 'jpg';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'webp';
      }
    }
    return 'jpg';
  }

  Future<void> _cleanupSelectedCoverTemp() async {
    final dirPath = _selectedCoverTempDir;
    final coverPath = _selectedCoverPath;
    _selectedCoverPath = null;
    _selectedCoverTempDir = null;
    _selectedCoverName = null;
    if (coverPath != null) {
      _coverDetails.remove(coverPath);
      _coverDetailLoads.remove(coverPath);
    }
    if (dirPath == null || dirPath.isEmpty) return;
    try {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
  }

  Future<void> _cleanupCurrentCoverTemp() async {
    final dirPath = _currentCoverTempDir;
    final coverPath = _currentCoverPath;
    _currentCoverPath = null;
    _currentCoverTempDir = null;
    if (coverPath != null) {
      _coverDetails.remove(coverPath);
      _coverDetailLoads.remove(coverPath);
    }
    if (dirPath == null || dirPath.isEmpty) return;
    try {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
  }

  Future<void> _loadCurrentCoverPreview() async {
    if (_loadingCurrentCover) return;
    setState(() => _loadingCurrentCover = true);
    String? newCoverPath;
    String? newCoverDir;
    try {
      final tempDir = await Directory.systemTemp.createTemp(
        'edit_existing_cover_',
      );
      final coverOutput =
          '${tempDir.path}${Platform.pathSeparator}existing_cover.jpg';
      final coverResult = await PlatformBridge.extractCoverToFile(
        widget.filePath,
        coverOutput,
      );
      if (coverResult['error'] == null && await File(coverOutput).exists()) {
        newCoverPath = coverOutput;
        newCoverDir = tempDir.path;
      } else {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }

    if (!mounted) {
      if (newCoverDir != null) {
        try {
          final dir = Directory(newCoverDir);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }
      return;
    }

    final oldDir = _currentCoverTempDir;
    final oldCoverPath = _currentCoverPath;
    setState(() {
      if (oldCoverPath != null && oldCoverPath != newCoverPath) {
        _coverDetails.remove(oldCoverPath);
        _coverDetailLoads.remove(oldCoverPath);
      }
      _currentCoverPath = newCoverPath;
      _currentCoverTempDir = newCoverDir;
      _loadingCurrentCover = false;
    });
    if (newCoverPath != null) {
      unawaited(_loadCoverDetails(newCoverPath));
    }
    if (oldDir != null && oldDir.isNotEmpty && oldDir != newCoverDir) {
      try {
        final dir = Directory(oldDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        _log.d('best-effort step failed: $e');
      }
    }
  }

  Future<void> _pickCoverImage() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      if (picked == null) return;

      final sourcePath = picked.path;
      final pickedExtension = p.extension(picked.name).replaceFirst('.', '');
      Uint8List? bytes;
      final needsByteFallback = !_hasValue(sourcePath);
      if (needsByteFallback) {
        bytes = await picked.readAsBytes();
      }
      final extension = _resolveImageExtension(pickedExtension, bytes);

      final tempDir = await Directory.systemTemp.createTemp('edit_cover_');
      final tempPath =
          '${tempDir.path}${Platform.pathSeparator}cover.$extension';

      if (sourcePath != null && sourcePath.isNotEmpty) {
        final sourceFile = File(sourcePath);
        if (!await sourceFile.exists()) {
          throw Exception('Selected image is not accessible');
        }
        await sourceFile.copy(tempPath);
      } else if (bytes != null && bytes.isNotEmpty) {
        await File(tempPath).writeAsBytes(bytes, flush: true);
      } else {
        throw Exception('Unable to read selected image');
      }

      await _cleanupSelectedCoverTemp();
      if (!mounted) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
        return;
      }
      setState(() {
        _selectedCoverPath = tempPath;
        _selectedCoverTempDir = tempDir.path;
        _selectedCoverName = picked.name;
      });
      unawaited(_loadCoverDetails(tempPath));
    } catch (e) {
      if (!mounted) return;
      _showSheetSnackBar(context.l10n.snackbarError(context.friendlyError(e)));
    }
  }

  String _fieldLabel(String key) {
    final l10n = context.l10n;
    switch (key) {
      case 'title':
        return l10n.editMetadataFieldTitle;
      case 'artist':
        return l10n.editMetadataFieldArtist;
      case 'album':
        return l10n.editMetadataFieldAlbum;
      case 'album_artist':
        return l10n.editMetadataFieldAlbumArtist;
      case 'date':
        return l10n.editMetadataFieldDate;
      case 'track_number':
        return l10n.editMetadataFieldTrackNum;
      case 'total_tracks':
        return l10n.editMetadataFieldTrackTotal;
      case 'disc_number':
        return l10n.editMetadataFieldDiscNum;
      case 'total_discs':
        return l10n.editMetadataFieldDiscTotal;
      case 'genre':
        return l10n.editMetadataFieldGenre;
      case 'isrc':
        return l10n.editMetadataFieldIsrc;
      case 'lyrics':
        return l10n.trackLyrics;
      case 'label':
        return l10n.editMetadataFieldLabel;
      case 'copyright':
        return l10n.editMetadataFieldCopyright;
      case 'composer':
        return l10n.editMetadataFieldComposer;
      case 'comment':
        return l10n.editMetadataFieldComment;
      case 'album_type':
        return l10n.trackAlbumType;
      case 'explicit':
        return l10n.editMetadataFieldExplicit;
      case 'upc':
        return l10n.editMetadataFieldUpc;
      case 'cover':
        return l10n.editMetadataFieldCover;
      default:
        return key;
    }
  }

  TextEditingController? _controllerForKey(String key) {
    switch (key) {
      case 'title':
        return _titleCtrl;
      case 'artist':
        return _artistCtrl;
      case 'album':
        return _albumCtrl;
      case 'album_artist':
        return _albumArtistCtrl;
      case 'date':
        return _dateCtrl;
      case 'track_number':
        return _trackNumCtrl;
      case 'total_tracks':
        return _trackTotalCtrl;
      case 'disc_number':
        return _discNumCtrl;
      case 'total_discs':
        return _discTotalCtrl;
      case 'genre':
        return _genreCtrl;
      case 'isrc':
        return _isrcCtrl;
      case 'lyrics':
        return _lyricsCtrl;
      case 'label':
        return _labelCtrl;
      case 'copyright':
        return _copyrightCtrl;
      case 'composer':
        return _composerCtrl;
      case 'comment':
        return _commentCtrl;
      case 'album_type':
        return _albumTypeCtrl;
      case 'upc':
        return _upcCtrl;
      default:
        return null;
    }
  }

  void _selectAllFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _autoFillFields.addAll(_fieldDefs.keys);
    });
  }

  void _selectEmptyFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _autoFillFields.clear();
      for (final key in _fieldDefs.keys) {
        if (key == 'explicit') continue;
        if (key == 'cover') {
          if (!_hasValue(_currentCoverPath) && !_hasValue(_selectedCoverPath)) {
            _autoFillFields.add(key);
          }
          continue;
        }
        final ctrl = _controllerForKey(key);
        if (ctrl != null && ctrl.text.trim().isEmpty) {
          _autoFillFields.add(key);
        }
      }
    });
  }

  void _selectNoFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _autoFillFields.clear();
    });
  }

  String _normalizeMetadataText(String value) {
    final collapsed = value
        .toLowerCase()
        .replaceAll(_metadataCollapsePattern, ' ')
        .trim();
    return collapsed.replaceAll(_metadataWhitespacePattern, ' ');
  }

  bool _looksLikeIsrc(String value) {
    return _isrcPattern.hasMatch(value.trim().toUpperCase());
  }

  String? _extractRawSpotifyTrackIdFromValue(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    if (_spotifyTrackIdPattern.hasMatch(raw)) {
      return raw;
    }

    if (raw.startsWith('spotify:')) {
      final parts = raw.split(':');
      final last = parts.isNotEmpty ? parts.last.trim() : '';
      if (_spotifyTrackIdPattern.hasMatch(last)) {
        return last;
      }
      return null;
    }

    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.host.contains('spotify.com') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'track') {
      final candidate = uri.pathSegments[1].trim();
      if (_spotifyTrackIdPattern.hasMatch(candidate)) {
        return candidate;
      }
    }

    return null;
  }

  String? _extractRawDeezerTrackIdFromValue(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    if (_deezerTrackIdPattern.hasMatch(raw)) {
      return raw;
    }

    if (raw.startsWith('deezer:')) {
      final parts = raw.split(':');
      final last = parts.isNotEmpty ? parts.last.trim() : '';
      if (_deezerTrackIdPattern.hasMatch(last)) {
        return last;
      }
    }

    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.contains('deezer.com')) {
      final trackIndex = uri.pathSegments.indexOf('track');
      if (trackIndex >= 0 && trackIndex + 1 < uri.pathSegments.length) {
        final candidate = uri.pathSegments[trackIndex + 1].trim();
        if (_deezerTrackIdPattern.hasMatch(candidate)) {
          return candidate;
        }
      }
    }

    return null;
  }

  String? _extractRawSpotifyTrackId(Map<String, dynamic> track) {
    for (final candidate in [track['spotify_id'], track['id']]) {
      final spotifyId = _extractRawSpotifyTrackIdFromValue(candidate);
      if (spotifyId != null) return spotifyId;
    }

    final externalLinks = track['external_links'];
    if (externalLinks is Map) {
      final spotifyId = _extractRawSpotifyTrackIdFromValue(
        externalLinks['spotify'],
      );
      if (spotifyId != null) return spotifyId;
    }

    return null;
  }

  String? _extractRawDeezerTrackId(Map<String, dynamic> track) {
    for (final candidate in [
      track['deezer_id'],
      track['spotify_id'],
      track['id'],
    ]) {
      final deezerId = _extractRawDeezerTrackIdFromValue(candidate);
      if (deezerId != null) return deezerId;
    }

    final externalLinks = track['external_links'];
    if (externalLinks is Map) {
      final deezerId = _extractRawDeezerTrackIdFromValue(
        externalLinks['deezer'],
      );
      if (deezerId != null) return deezerId;
    }

    return null;
  }

  Map<String, dynamic> _unwrapTrackPayload(Map<String, dynamic> payload) {
    final track = payload['track'];
    if (track is Map<String, dynamic>) {
      return track;
    }
    return payload;
  }

  void _mergeOnlineTrackData(
    Map<String, String> enriched,
    Map<String, dynamic> track,
  ) {
    void put(String key, Object? value) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != 'null') {
        enriched[key] = text;
      }
    }

    put('title', track['name'] ?? track['title']);
    put('artist', track['artists'] ?? track['artist']);
    put('album', track['album_name'] ?? track['album']);
    put('album_artist', track['album_artist']);
    put('date', track['release_date']);
    put('track_number', track['track_number']);
    put('total_tracks', track['total_tracks']);
    put('disc_number', track['disc_number']);
    put('total_discs', track['total_discs']);
    put('isrc', track['isrc']);
    put('genre', track['genre']);
    put('label', track['label']);
    put('copyright', track['copyright']);
    put('composer', track['composer']);
    put('comment', track['comment']);
    put('album_type', track['album_type'] ?? track['albumType']);
    put('explicit', track['explicit'] ?? track['is_explicit']);
    put('upc', track['upc'] ?? track['barcode']);
  }

  int _metadataMatchScore(
    Map<String, dynamic> track, {
    required String currentTitle,
    required String currentArtist,
    required String currentAlbum,
    required String currentIsrc,
  }) {
    var score = 0;

    final candidateIsrc = (track['isrc']?.toString() ?? '')
        .trim()
        .toUpperCase();
    if (currentIsrc.isNotEmpty && candidateIsrc == currentIsrc) {
      score += 10000;
    }

    final candidateTitle = _normalizeMetadataText(
      (track['name'] ?? track['title'] ?? '').toString(),
    );
    final candidateArtist = _normalizeMetadataText(
      (track['artists'] ?? track['artist'] ?? '').toString(),
    );
    final candidateAlbum = _normalizeMetadataText(
      (track['album_name'] ?? track['album'] ?? '').toString(),
    );

    if (currentTitle.isNotEmpty && candidateTitle.isNotEmpty) {
      if (candidateTitle == currentTitle) {
        score += 400;
      } else if (candidateTitle.contains(currentTitle) ||
          currentTitle.contains(candidateTitle)) {
        score += 180;
      }
    }

    if (currentArtist.isNotEmpty && candidateArtist.isNotEmpty) {
      if (candidateArtist == currentArtist) {
        score += 320;
      } else if (candidateArtist.contains(currentArtist) ||
          currentArtist.contains(candidateArtist)) {
        score += 140;
      }
    }

    if (currentAlbum.isNotEmpty && candidateAlbum.isNotEmpty) {
      if (candidateAlbum == currentAlbum) {
        score += 120;
      } else if (candidateAlbum.contains(currentAlbum) ||
          currentAlbum.contains(candidateAlbum)) {
        score += 50;
      }
    }

    return score;
  }

  bool _metadataTextMatches(String current, String candidate) {
    if (current.isEmpty || candidate.isEmpty) return false;
    return current == candidate ||
        candidate.contains(current) ||
        current.contains(candidate);
  }

  bool _metadataMatchIsConfident(
    Map<String, dynamic> track, {
    required String currentTitle,
    required String currentArtist,
    required String currentAlbum,
    required String currentIsrc,
  }) {
    final candidateIsrc = (track['isrc']?.toString() ?? '')
        .trim()
        .toUpperCase();
    if (currentIsrc.isNotEmpty && candidateIsrc == currentIsrc) {
      return true;
    }

    final candidateTitle = _normalizeMetadataText(
      (track['name'] ?? track['title'] ?? '').toString(),
    );
    final candidateArtist = _normalizeMetadataText(
      (track['artists'] ?? track['artist'] ?? '').toString(),
    );
    final candidateAlbum = _normalizeMetadataText(
      (track['album_name'] ?? track['album'] ?? '').toString(),
    );

    final titleMatches = _metadataTextMatches(currentTitle, candidateTitle);
    final artistMatches = _metadataTextMatches(currentArtist, candidateArtist);
    final albumMatches = _metadataTextMatches(currentAlbum, candidateAlbum);

    if (currentTitle.isNotEmpty && currentArtist.isNotEmpty) {
      return titleMatches && artistMatches;
    }
    if (currentTitle.isNotEmpty && currentAlbum.isNotEmpty) {
      return titleMatches && albumMatches;
    }
    if (currentTitle.isNotEmpty) {
      return titleMatches;
    }
    if (currentAlbum.isNotEmpty) {
      return albumMatches;
    }

    return false;
  }

  Future<List<Map<String, dynamic>>> _searchAutoFillCandidates({
    required String query,
    required bool usesAutomaticProvider,
    required Extension? selectedProvider,
    required ExtensionState extensionState,
    bool allowVerificationRetry = true,
  }) async {
    try {
      if (usesAutomaticProvider) {
        return await PlatformBridge.searchTracksWithMetadataProviders(
          query,
          limit: 5,
        );
      }

      final provider = selectedProvider!;
      if (provider.hasCustomSearch) {
        final trackFilter = provider.searchBehavior?.filterIdForKind('track');
        return await PlatformBridge.customSearchWithExtension(
          provider.id,
          query,
          options: {'limit': 5, 'filter': ?trackFilter},
        );
      }
      return await PlatformBridge.searchTracksWithMetadataProvider(
        provider.id,
        query,
        limit: 5,
      );
    } catch (error) {
      if (!allowVerificationRetry || !isExtensionVerificationRequired(error)) {
        rethrow;
      }

      final extensionId = usesAutomaticProvider
          ? extensionIdFromVerificationError(
              error,
              extensionState.extensions.map((extension) => extension.id),
            )
          : selectedProvider?.id;
      if (extensionId == null || extensionId.isEmpty) rethrow;

      _log.i(
        'Metadata autofill requires verification; waiting for $extensionId',
      );
      final verified = await openVerificationAndAwaitGrant(
        extensionId,
        browserMode: ProviderScope.containerOf(
          context,
          listen: false,
        ).read(settingsProvider).extensionVerificationBrowserMode,
      );
      if (!verified || !mounted) rethrow;

      return _searchAutoFillCandidates(
        query: query,
        usesAutomaticProvider: usesAutomaticProvider,
        selectedProvider: selectedProvider,
        extensionState: extensionState,
        allowVerificationRetry: false,
      );
    }
  }

  String? _metadataCandidateCoverUrl(Map<String, dynamic> track) {
    String? fromValue(Object? value) {
      if (value is String) {
        final normalized = value.trim();
        return normalized.isEmpty ? null : normalized;
      }
      if (value is List) {
        for (final item in value) {
          final resolved = fromValue(item);
          if (resolved != null) return resolved;
        }
      }
      if (value is Map) {
        for (final key in const ['url', 'original', 'large', 'src']) {
          final resolved = fromValue(value[key]);
          if (resolved != null) return resolved;
        }
      }
      return null;
    }

    return fromValue(track['cover_url']) ?? fromValue(track['images']);
  }

  Future<Map<String, dynamic>?> _showAutoFillCandidatePicker({
    required List<Map<String, dynamic>> candidates,
    required String sourceName,
    required String currentTitle,
    required String currentArtist,
  }) {
    return showAppBottomSheet<Map<String, dynamic>>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      title: context.l10n.editMetadataAutoFillSource,
      subtitle: [
        currentTitle,
        currentArtist,
        sourceName,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      maxHeightFactor: 0.82,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(
            children: [
              for (var index = 0; index < candidates.length; index++) ...[
                Builder(
                  builder: (context) {
                    final candidate = candidates[index];
                    final title =
                        (candidate['name'] ?? candidate['title'] ?? '')
                            .toString()
                            .trim();
                    final artists =
                        (candidate['artists'] ?? candidate['artist'] ?? '')
                            .toString()
                            .trim();
                    final album =
                        (candidate['album_name'] ?? candidate['album'] ?? '')
                            .toString()
                            .trim();
                    final date =
                        candidate['release_date']?.toString().trim() ?? '';
                    final isrc = candidate['isrc']?.toString().trim() ?? '';
                    final coverUrl = _metadataCandidateCoverUrl(candidate);
                    final subtitle = [
                      artists,
                      album,
                      if (date.isNotEmpty) date,
                      if (isrc.isNotEmpty) 'ISRC $isrc',
                    ].where((value) => value.isNotEmpty).join('\n');

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      leading: _MetadataCandidateArtwork(coverUrl: coverUrl),
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: subtitle.isEmpty
                          ? null
                          : Text(
                              subtitle,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(sheetContext, candidate),
                    );
                  },
                ),
                if (index != candidates.length - 1)
                  Divider(
                    height: 1,
                    indent: 88,
                    endIndent: 16,
                    color: Theme.of(
                      sheetContext,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _fetchAutoFillPreview() async {
    if (_autoFillFields.isEmpty) {
      _showSheetSnackBar(context.l10n.editMetadataAutoFillNoneSelected);
      return;
    }

    setState(() {
      _fetching = true;
      _invalidateAutoFillPreview();
    });
    final settingsNotifier = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(settingsProvider.notifier);

    try {
      final title = _titleCtrl.text.trim();
      final artist = _artistCtrl.text.trim();
      final album = _albumCtrl.text.trim();
      final albumArtist = _albumArtistCtrl.text.trim();
      final searchArtist = primaryArtistName(artist, albumArtist: albumArtist);
      final currentIsrc = _isrcCtrl.text.trim().toUpperCase();
      final configuredProviderId = _selectedMetadataProviderId?.trim();
      final extensionState = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(extensionProvider);
      final selectedProvider = configuredProviderId == null
          ? null
          : extensionState.extensions
                .where(
                  (extension) =>
                      extension.id == configuredProviderId &&
                      extension.enabled &&
                      extension.hasMetadataProvider,
                )
                .firstOrNull;
      final selectedProviderId = selectedProvider?.id;
      final usesAutomaticProvider =
          selectedProviderId == null || selectedProviderId.isEmpty;
      final shouldFetchLyrics = _autoFillFields.contains('lyrics');
      final needsTrackLookup = _autoFillFields.any((key) => key != 'lyrics');
      Map<String, dynamic>? best;
      String? deezerId;
      String? lyricsSourceName;

      final queryParts = <String>[];
      if (title.isNotEmpty) queryParts.add(title);
      if (searchArtist.isNotEmpty) queryParts.add(searchArtist);
      if (queryParts.isEmpty && album.isNotEmpty) queryParts.add(album);

      if (needsTrackLookup && queryParts.isEmpty) {
        if (mounted) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
        }
        return;
      }

      final normalizedTitle = _normalizeMetadataText(title);
      final normalizedArtist = _normalizeMetadataText(searchArtist);
      final normalizedAlbum = _normalizeMetadataText(album);

      if (needsTrackLookup) {
        final query = queryParts.join(' ');
        final results = await _searchAutoFillCandidates(
          query: query,
          usesAutomaticProvider: usesAutomaticProvider,
          selectedProvider: selectedProvider,
          extensionState: extensionState,
        );

        if (!mounted) return;

        if (results.isEmpty) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
          return;
        }

        final rankedResults = [...results]
          ..sort((a, b) {
            final aScore = _metadataMatchScore(
              a,
              currentTitle: normalizedTitle,
              currentArtist: normalizedArtist,
              currentAlbum: normalizedAlbum,
              currentIsrc: currentIsrc,
            );
            final bScore = _metadataMatchScore(
              b,
              currentTitle: normalizedTitle,
              currentArtist: normalizedArtist,
              currentAlbum: normalizedAlbum,
              currentIsrc: currentIsrc,
            );
            return bScore.compareTo(aScore);
          });

        if (usesAutomaticProvider) {
          best = rankedResults.first;
          if (!_metadataMatchIsConfident(
            best,
            currentTitle: normalizedTitle,
            currentArtist: normalizedArtist,
            currentAlbum: normalizedAlbum,
            currentIsrc: currentIsrc,
          )) {
            best = null;
          }
        } else {
          best = await _showAutoFillCandidatePicker(
            candidates: rankedResults,
            sourceName: _metadataProviderName(selectedProviderId),
            currentTitle: title,
            currentArtist: searchArtist,
          );
          if (!mounted || best == null) return;
        }

        if (best == null) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
          return;
        }

        if (!usesAutomaticProvider) {
          final trackId = best['id']?.toString().trim() ?? '';
          if (trackId.isNotEmpty) {
            try {
              final details = await PlatformBridge.getProviderMetadata(
                selectedProviderId,
                'track',
                trackId,
              );
              final mergedDetails = <String, dynamic>{...best};
              for (final entry in _unwrapTrackPayload(details).entries) {
                final value = entry.value;
                if (value != null && value.toString().trim().isNotEmpty) {
                  mergedDetails[entry.key] = value;
                }
              }
              best = mergedDetails;
            } catch (e) {
              _log.w(
                'Detailed metadata lookup failed for '
                '$selectedProviderId/$trackId: $e',
              );
            }
          }
        }
      }

      final selectedBest = best;
      if (needsTrackLookup && selectedBest == null) {
        throw StateError('No metadata match resolved for auto-fill');
      }

      final enriched = <String, String>{};
      if (selectedBest != null) {
        enriched.addAll(<String, String>{
          'title': (selectedBest['name'] ?? '').toString(),
          'artist': (selectedBest['artists'] ?? selectedBest['artist'] ?? '')
              .toString(),
          'album': (selectedBest['album_name'] ?? selectedBest['album'] ?? '')
              .toString(),
          'album_artist': (selectedBest['album_artist'] ?? '').toString(),
          'date': (selectedBest['release_date'] ?? '').toString(),
          'track_number': (selectedBest['track_number'] ?? '').toString(),
          'total_tracks': (selectedBest['total_tracks'] ?? '').toString(),
          'disc_number': (selectedBest['disc_number'] ?? '').toString(),
          'total_discs': (selectedBest['total_discs'] ?? '').toString(),
          'isrc': (selectedBest['isrc'] ?? '').toString(),
          'composer': (selectedBest['composer'] ?? '').toString(),
        });
        _mergeOnlineTrackData(enriched, selectedBest);
      }

      final enrichedIsrc = (enriched['isrc'] ?? '').trim();
      final needsIsrc =
          _autoFillFields.contains('isrc') && enrichedIsrc.isEmpty;
      final needsExtended =
          _autoFillFields.contains('genre') ||
          _autoFillFields.contains('label') ||
          _autoFillFields.contains('copyright') ||
          _autoFillFields.contains('composer');

      final rawSpotifyId = selectedBest == null
          ? _extractRawSpotifyTrackIdFromValue(widget.sourceTrackId)
          : _extractRawSpotifyTrackId(selectedBest);

      deezerId ??= selectedBest == null
          ? null
          : _extractRawDeezerTrackId(selectedBest);
      final candidateIsrc = enrichedIsrc.toUpperCase();
      final deezerLookupIsrc = _looksLikeIsrc(currentIsrc)
          ? currentIsrc
          : (_looksLikeIsrc(candidateIsrc) ? candidateIsrc : '');

      if (usesAutomaticProvider && (needsIsrc || needsExtended)) {
        try {
          if (deezerId == null && deezerLookupIsrc.isNotEmpty) {
            final deezerResult = await PlatformBridge.searchDeezerByISRC(
              deezerLookupIsrc,
            );
            deezerId = _extractRawDeezerTrackId(deezerResult);
            _mergeOnlineTrackData(enriched, deezerResult);
          }

          if (deezerId == null && rawSpotifyId != null) {
            // Spotify IDs can be mapped through SongLink to a Deezer track.
            final deezerData = await PlatformBridge.convertSpotifyToDeezer(
              'track',
              rawSpotifyId,
            );
            final trackData = deezerData['track'];
            if (trackData is Map<String, dynamic>) {
              deezerId = _extractRawDeezerTrackId(trackData);
              _mergeOnlineTrackData(enriched, trackData);
            }
            deezerId ??= _extractRawDeezerTrackId(deezerData);
          }
        } catch (_) {
          // Deezer resolution is best-effort
        }
      }

      if (!mounted) return;

      if (usesAutomaticProvider &&
          needsIsrc &&
          (enriched['isrc'] ?? '').trim().isEmpty &&
          deezerId != null) {
        try {
          final deezerMeta = await PlatformBridge.getProviderMetadata(
            'deezer',
            'track',
            deezerId,
          );
          final trackData = _unwrapTrackPayload(deezerMeta);
          _mergeOnlineTrackData(enriched, trackData);
          final deezerIsrc = (trackData['isrc'] ?? '').toString().trim();
          if (deezerIsrc.isNotEmpty) {
            enriched['isrc'] = deezerIsrc;
          }
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }

      if (!mounted) return;

      if (usesAutomaticProvider && needsExtended && deezerId != null) {
        try {
          final extended = await PlatformBridge.getDeezerExtendedMetadata(
            deezerId,
          );
          if (extended != null) {
            enriched['genre'] = extended['genre'] ?? '';
            enriched['label'] = extended['label'] ?? '';
            enriched['copyright'] = extended['copyright'] ?? '';
          }
        } catch (_) {
          // Extended metadata is best-effort
        }
      }

      if (shouldFetchLyrics) {
        await settingsNotifier.syncLyricsSettingsToBackend();

        if (!mounted) return;

        final lyricsTitle =
            ((selectedBest?['name'] ?? selectedBest?['title'] ?? title)
                    .toString())
                .trim();
        final lyricsArtist =
            ((selectedBest?['artists'] ?? selectedBest?['artist'] ?? artist)
                    .toString())
                .trim();

        if (lyricsTitle.isNotEmpty && lyricsArtist.isNotEmpty) {
          try {
            final lyricsResult = await PlatformBridge.getLyricsLRCWithSource(
              rawSpotifyId ?? '',
              lyricsTitle,
              lyricsArtist,
              durationMs: widget.durationMs,
            );
            final lyricsText = lyricsResult['lyrics']?.toString().trim() ?? '';
            final lyricsSource =
                lyricsResult['source']?.toString().trim() ?? '';
            if (lyricsSource.isNotEmpty) lyricsSourceName = lyricsSource;
            final instrumental =
                (lyricsResult['instrumental'] as bool? ?? false) ||
                lyricsText == '[instrumental:true]';
            if (!instrumental && lyricsText.isNotEmpty) {
              enriched['lyrics'] = lyricsText;
            }
          } catch (e) {
            _log.w('Lyrics autofill failed: $e');
          }
        }
      }

      if (!mounted) return;

      final availableValues = <String, String>{};
      for (final entry in enriched.entries) {
        final value = entry.value.trim();
        final isExplicitValue = entry.key == 'explicit';
        if (value.isNotEmpty &&
            (isExplicitValue || value != '0') &&
            value != 'null') {
          availableValues[entry.key] = value;
        }
      }
      final coverUrl = selectedBest == null
          ? null
          : _metadataCandidateCoverUrl(selectedBest);
      final hasSelectedValue = _autoFillFields.any(
        (key) => key == 'cover'
            ? coverUrl != null && coverUrl.isNotEmpty
            : availableValues.containsKey(key),
      );
      if (!hasSelectedValue) {
        _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
        return;
      }

      final coverPreview =
          _autoFillFields.contains('cover') &&
              coverUrl != null &&
              coverUrl.isNotEmpty
          ? await _downloadAutoFillCoverPreview(coverUrl)
          : null;
      if (!mounted) {
        if (coverPreview != null) {
          await _deleteTempDirectory(coverPreview.tempDir);
        }
        return;
      }

      final resolvedSourceId = selectedProviderId?.isNotEmpty == true
          ? selectedProviderId!
          : (selectedBest?['provider_id']?.toString().trim() ?? '');
      final resolvedSourceName =
          selectedBest == null && lyricsSourceName?.isNotEmpty == true
          ? lyricsSourceName!
          : _metadataProviderName(resolvedSourceId);
      setState(() {
        _autoFillPreview = _AutoFillPreview(
          values: availableValues,
          sourceName: resolvedSourceName,
          coverUrl: coverUrl?.isNotEmpty == true ? coverUrl : null,
          coverPath: coverPreview?.path,
          coverTempDir: coverPreview?.tempDir,
          coverDetails: coverPreview?.details,
        );
        if (coverPreview?.details case final details?) {
          _coverDetails[coverPreview!.path] = details;
        }
      });
    } catch (e, stackTrace) {
      _log.e('Metadata auto-fill failed: $e', e, stackTrace);
      if (mounted) {
        _showSheetSnackBar(
          context.l10n.snackbarError(context.friendlyError(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _applyAutoFillPreview() async {
    final preview = _autoFillPreview;
    if (preview == null || _saving || _fetching) return;

    setState(() => _fetching = true);
    try {
      var filledCount = 0;
      for (final key in _autoFillFields) {
        if (key == 'cover') continue;
        final value = preview.values[key];
        if (key == 'explicit' && value != null) {
          final parsed = parseExplicitFlag(value);
          if (parsed != null) {
            _explicit = parsed;
            filledCount++;
          }
          continue;
        }
        final ctrl = _controllerForKey(key);
        if (value != null && ctrl != null) {
          ctrl.text = value;
          filledCount++;
        }
      }

      if (_autoFillFields.contains('cover') && preview.coverUrl != null) {
        var coverPath = preview.coverPath;
        var coverTempDir = preview.coverTempDir;
        var coverDetails = preview.coverDetails;
        if (coverPath == null ||
            coverTempDir == null ||
            !await File(coverPath).exists()) {
          final downloaded = await _downloadAutoFillCoverPreview(
            preview.coverUrl!,
          );
          coverPath = downloaded?.path;
          coverTempDir = downloaded?.tempDir;
          coverDetails = downloaded?.details;
        }
        if (coverPath != null && coverTempDir != null) {
          await _cleanupSelectedCoverTemp();
          if (mounted) {
            _selectedCoverPath = coverPath;
            _selectedCoverTempDir = coverTempDir;
            _selectedCoverName = _EditMetadataSheet._onlineCoverSentinel;
            if (coverDetails != null) {
              _coverDetails[coverPath] = coverDetails;
            } else {
              unawaited(_loadCoverDetails(coverPath));
            }
            filledCount++;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        if (filledCount > 0) {
          final previewCoverWasTransferred =
              preview.coverPath != null &&
              preview.coverPath == _selectedCoverPath;
          if (previewCoverWasTransferred) {
            _autoFillPreview = null;
          } else {
            _invalidateAutoFillPreview();
          }
        }
      });
      _showSheetSnackBar(
        filledCount > 0
            ? context.l10n.editMetadataAutoFillDoneFromSource(
                filledCount,
                preview.sourceName,
              )
            : context.l10n.editMetadataAutoFillNoResults,
      );
    } catch (e) {
      if (mounted) {
        _showSheetSnackBar(
          context.l10n.snackbarError(context.friendlyError(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final v = widget.initialValues;
    _titleCtrl = TextEditingController(text: v['title'] ?? '');
    _artistCtrl = TextEditingController(text: v['artist'] ?? '');
    _albumCtrl = TextEditingController(text: v['album'] ?? '');
    _albumArtistCtrl = TextEditingController(text: v['album_artist'] ?? '');
    _dateCtrl = TextEditingController(text: v['date'] ?? '');
    _trackNumCtrl = TextEditingController(text: v['track_number'] ?? '');
    _trackTotalCtrl = TextEditingController(text: v['total_tracks'] ?? '');
    _discNumCtrl = TextEditingController(text: v['disc_number'] ?? '');
    _discTotalCtrl = TextEditingController(text: v['total_discs'] ?? '');
    _genreCtrl = TextEditingController(text: v['genre'] ?? '');
    _isrcCtrl = TextEditingController(text: v['isrc'] ?? '');
    _lyricsCtrl = TextEditingController(text: v['lyrics'] ?? '');
    _labelCtrl = TextEditingController(text: v['label'] ?? '');
    _copyrightCtrl = TextEditingController(text: v['copyright'] ?? '');
    _composerCtrl = TextEditingController(text: v['composer'] ?? '');
    _commentCtrl = TextEditingController(text: v['comment'] ?? '');
    _albumTypeCtrl = TextEditingController(text: v['album_type'] ?? '');
    _upcCtrl = TextEditingController(text: v['upc'] ?? '');
    _explicit = parseExplicitFlag(v['explicit']) == true;
    _loadCurrentCoverPreview();
  }

  @override
  void dispose() {
    _invalidateAutoFillPreview();
    unawaited(_cleanupSelectedCoverTemp());
    unawaited(_cleanupCurrentCoverTemp());
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    _albumArtistCtrl.dispose();
    _dateCtrl.dispose();
    _trackNumCtrl.dispose();
    _trackTotalCtrl.dispose();
    _discNumCtrl.dispose();
    _discTotalCtrl.dispose();
    _genreCtrl.dispose();
    _isrcCtrl.dispose();
    _lyricsCtrl.dispose();
    _labelCtrl.dispose();
    _copyrightCtrl.dispose();
    _composerCtrl.dispose();
    _commentCtrl.dispose();
    _albumTypeCtrl.dispose();
    _upcCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final noCoverMessage = context.l10n.trackCoverNoEmbeddedArt;
    final resizeFailedMessage = context.l10n.trackCoverResizeFailed;
    Directory? resizedCoverTempDir;
    try {
      String? coverPathForSave = _selectedCoverPath;
      final requestedCoverDimension = _coverMaxDimension;
      if (requestedCoverDimension != null) {
        final sourceCoverPath = _selectedCoverPath ?? _currentCoverPath;
        if (!_hasValue(sourceCoverPath)) {
          throw StateError(noCoverMessage);
        }
        resizedCoverTempDir = await Directory.systemTemp.createTemp(
          'edit_resized_cover_',
        );
        final resizedCoverPath =
            '${resizedCoverTempDir.path}${Platform.pathSeparator}'
            'cover_${requestedCoverDimension}px.jpg';
        final resized = await FFmpegService.resizeCoverArt(
          inputPath: sourceCoverPath!,
          outputPath: resizedCoverPath,
          maxDimension: requestedCoverDimension,
        );
        if (!resized) {
          throw StateError(resizeFailedMessage);
        }
        coverPathForSave = resizedCoverPath;
      }

      final metadata = <String, String>{
        'title': _titleCtrl.text,
        'artist': _artistCtrl.text,
        'album': _albumCtrl.text,
        'album_artist': _albumArtistCtrl.text,
        'date': _dateCtrl.text,
        'track_number': _trackNumCtrl.text,
        'track_total': _trackTotalCtrl.text,
        'disc_number': _discNumCtrl.text,
        'disc_total': _discTotalCtrl.text,
        'genre': _genreCtrl.text,
        'isrc': _isrcCtrl.text,
        'lyrics': _lyricsCtrl.text,
        'label': _labelCtrl.text,
        'copyright': _copyrightCtrl.text,
        'composer': _composerCtrl.text,
        'comment': _commentCtrl.text,
        'album_type': _albumTypeCtrl.text,
        'explicit': _explicit ? '1' : '0',
        'upc': _upcCtrl.text,
        'compilation': _albumTypeCtrl.text.trim().toLowerCase() == 'compilation'
            ? '1'
            : '0',
        'cover_path': coverPathForSave ?? '',
        'artist_tag_mode': widget.artistTagMode,
      };

      final result = await PlatformBridge.editFileMetadata(
        widget.filePath,
        metadata,
      );

      if (result['error'] != null) {
        if (mounted) {
          _showSheetSnackBar(
            context.friendlyError(
              result['error'],
              fallback: context.l10n.metadataSaveFailedFfmpeg,
            ),
          );
        }
        return;
      }

      final method = result['method'] as String?;

      if (method == 'ffmpeg') {
        // For SAF files, Kotlin returns temp_path + saf_uri
        final tempPath = result['temp_path'] as String?;
        final safUri = result['saf_uri'] as String?;
        final ffmpegTarget = tempPath ?? widget.filePath;

        final lower = widget.filePath.toLowerCase();
        final isMp3 = lower.endsWith('.mp3');
        final isOpus = lower.endsWith('.opus') || lower.endsWith('.ogg');
        final isM4A = lower.endsWith('.m4a') || lower.endsWith('.aac');

        // Always include all known fields so -map_metadata 0 + explicit
        // -metadata flags can both preserve custom tags AND clear fields
        // the user emptied.
        final vorbisMap = <String, String>{
          'TITLE': metadata['title'] ?? '',
          'ARTIST': metadata['artist'] ?? '',
          'ALBUM': metadata['album'] ?? '',
          'ALBUMARTIST': metadata['album_artist'] ?? '',
          'DATE': metadata['date'] ?? '',
          'TRACKNUMBER':
              (metadata['track_number']?.isNotEmpty == true &&
                  metadata['track_number'] != '0')
              ? (metadata['track_total']?.isNotEmpty == true &&
                        metadata['track_total'] != '0'
                    ? '${metadata['track_number']}/${metadata['track_total']}'
                    : metadata['track_number']!)
              : '',
          'DISCNUMBER':
              (metadata['disc_number']?.isNotEmpty == true &&
                  metadata['disc_number'] != '0')
              ? (metadata['disc_total']?.isNotEmpty == true &&
                        metadata['disc_total'] != '0'
                    ? '${metadata['disc_number']}/${metadata['disc_total']}'
                    : metadata['disc_number']!)
              : '',
          'GENRE': metadata['genre'] ?? '',
          'ISRC': metadata['isrc'] ?? '',
          'LYRICS': metadata['lyrics'] ?? '',
          'UNSYNCEDLYRICS': metadata['lyrics'] ?? '',
          'ORGANIZATION': metadata['label'] ?? '',
          'COPYRIGHT': metadata['copyright'] ?? '',
          'COMPOSER': metadata['composer'] ?? '',
          'COMMENT': metadata['comment'] ?? '',
          'ITUNESADVISORY': metadata['explicit'] ?? '',
          'RELEASETYPE': metadata['album_type'] ?? '',
          'BARCODE': metadata['upc'] ?? '',
          'COMPILATION': metadata['compilation'] ?? '',
        };
        try {
          final existingMetadata = await PlatformBridge.readFileMetadata(
            ffmpegTarget,
          );
          // Preserve ReplayGain tags if present — these are computed once
          // during download and should survive manual metadata edits.
          final rgFields = <String, String>{
            'REPLAYGAIN_TRACK_GAIN':
                existingMetadata['replaygain_track_gain']?.toString() ?? '',
            'REPLAYGAIN_TRACK_PEAK':
                existingMetadata['replaygain_track_peak']?.toString() ?? '',
            'REPLAYGAIN_ALBUM_GAIN':
                existingMetadata['replaygain_album_gain']?.toString() ?? '',
            'REPLAYGAIN_ALBUM_PEAK':
                existingMetadata['replaygain_album_peak']?.toString() ?? '',
          };
          rgFields.forEach((key, value) {
            if (value.isNotEmpty) {
              vorbisMap[key] = value;
            }
          });
        } catch (_) {
          // Lyrics/ReplayGain preservation is best-effort.
        }

        String? existingCoverPath = coverPathForSave ?? _currentCoverPath;
        String? extractedCoverPath;
        if (existingCoverPath == null || existingCoverPath.isEmpty) {
          // Preserve current embedded cover when user does not pick a new one.
          try {
            final tempDir = await Directory.systemTemp.createTemp('cover_');
            final coverOutput =
                '${tempDir.path}${Platform.pathSeparator}cover.jpg';
            final coverResult = await PlatformBridge.extractCoverToFile(
              ffmpegTarget,
              coverOutput,
            );
            if (coverResult['error'] == null) {
              existingCoverPath = coverOutput;
              extractedCoverPath = coverOutput;
            } else {
              try {
                await tempDir.delete(recursive: true);
              } catch (e) {
                _log.d('best-effort step failed: $e');
              }
            }
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
        }

        String? ffmpegResult;
        if (isMp3) {
          ffmpegResult = await FFmpegService.embedMetadataToMp3(
            mp3Path: ffmpegTarget,
            coverPath: existingCoverPath,
            metadata: vorbisMap,
            preserveMetadata: true,
          );
        } else if (isM4A) {
          ffmpegResult = await FFmpegService.embedMetadataToM4a(
            m4aPath: ffmpegTarget,
            coverPath: existingCoverPath,
            metadata: vorbisMap,
            preserveMetadata: true,
          );
        } else if (isOpus) {
          ffmpegResult = await FFmpegService.embedMetadataToOpus(
            opusPath: ffmpegTarget,
            coverPath: existingCoverPath,
            metadata: vorbisMap,
            artistTagMode: widget.artistTagMode,
            preserveMetadata: true,
          );
        }

        // Cleanup extracted temp cover (manual selected cover is cleaned on dispose)
        if (extractedCoverPath != null && extractedCoverPath.isNotEmpty) {
          final extractedFile = File(extractedCoverPath);
          try {
            await extractedFile.delete();
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
          try {
            final dir = extractedFile.parent;
            if (await dir.exists()) {
              await dir.delete(recursive: true);
            }
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
        }

        if (ffmpegResult == null) {
          if (mounted) {
            _showSheetSnackBar(context.l10n.metadataSaveFailedFfmpeg);
          }
          return;
        }

        if (tempPath != null && safUri != null) {
          final ok = await PlatformBridge.writeTempToSaf(ffmpegResult, safUri);
          if (!ok) {
            if (mounted) {
              _showSheetSnackBar(context.l10n.metadataSaveFailedStorage);
            }
            return;
          }
        }
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        _showSheetSnackBar(
          context.l10n.snackbarError(context.friendlyError(e)),
        );
      }
    } finally {
      if (resizedCoverTempDir != null) {
        try {
          if (await resizedCoverTempDir.exists()) {
            await resizedCoverTempDir.delete(recursive: true);
          }
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => ScaffoldMessenger(
          key: _sheetMessengerKey,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: const AppSheetHandle(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.trackEditMetadata,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (_saving)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(context.l10n.dialogSave),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    children: [
                      _buildCoverEditor(cs),
                      _buildAutoFillSection(cs),
                      _sectionCard(
                        icon: Icons.info_outline,
                        title: context.l10n.trackMetadata,
                        children: [
                          _field(
                            context.l10n.editMetadataFieldTitle,
                            _titleCtrl,
                          ),
                          _field(
                            context.l10n.editMetadataFieldArtist,
                            _artistCtrl,
                          ),
                          _field(
                            context.l10n.editMetadataFieldAlbum,
                            _albumCtrl,
                          ),
                          _field(
                            context.l10n.editMetadataFieldAlbumArtist,
                            _albumArtistCtrl,
                          ),
                          _field(
                            context.l10n.editMetadataFieldDate,
                            _dateCtrl,
                            hint: context.l10n.editMetadataFieldDateHint,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: _field(
                                  context.l10n.editMetadataFieldTrackNum,
                                  _trackNumCtrl,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _field(
                                  context.l10n.editMetadataFieldTrackTotal,
                                  _trackTotalCtrl,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: _field(
                                  context.l10n.editMetadataFieldDiscNum,
                                  _discNumCtrl,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _field(
                                  context.l10n.editMetadataFieldDiscTotal,
                                  _discTotalCtrl,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          _field(
                            context.l10n.editMetadataFieldGenre,
                            _genreCtrl,
                          ),
                          _field(context.l10n.editMetadataFieldIsrc, _isrcCtrl),
                        ],
                      ),
                      _sectionCard(
                        icon: Icons.lyrics_outlined,
                        title: context.l10n.trackLyrics,
                        children: [
                          _field(
                            context.l10n.trackLyrics,
                            _lyricsCtrl,
                            maxLines: 8,
                            keyboard: TextInputType.multiline,
                          ),
                        ],
                      ),
                      _sectionCard(
                        icon: Icons.tune,
                        title: context.l10n.editMetadataAdvanced,
                        onHeaderTap: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        expanded: _showAdvanced,
                        children: [
                          if (_showAdvanced) ...[
                            _field(
                              context.l10n.editMetadataFieldLabel,
                              _labelCtrl,
                            ),
                            _field(
                              context.l10n.editMetadataFieldCopyright,
                              _copyrightCtrl,
                            ),
                            _field(
                              context.l10n.editMetadataFieldComposer,
                              _composerCtrl,
                            ),
                            _field(
                              context.l10n.trackAlbumType,
                              _albumTypeCtrl,
                              hint: context.l10n.editMetadataFieldAlbumTypeHint,
                            ),
                            _switchField(
                              label: context.l10n.editMetadataFieldExplicit,
                              subtitle:
                                  context.l10n.editMetadataFieldExplicitHint,
                              value: _explicit,
                              onChanged: (value) =>
                                  setState(() => _explicit = value),
                            ),
                            _field(
                              context.l10n.editMetadataFieldUpc,
                              _upcCtrl,
                              hint: context.l10n.editMetadataFieldUpcHint,
                              keyboard: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(18),
                              ],
                            ),
                            _field(
                              context.l10n.editMetadataFieldComment,
                              _commentCtrl,
                              maxLines: 3,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoFillSection(ColorScheme cs) {
    return _sectionCard(
      icon: Icons.travel_explore,
      title: context.l10n.editMetadataAutoFill,
      onHeaderTap: () => setState(() => _showAutoFill = !_showAutoFill),
      expanded: _showAutoFill,
      children: [
        if (_showAutoFill) ...[
          Text(
            context.l10n.editMetadataAutoFillDesc,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Consumer(
            builder: (context, ref, _) {
              final extensionState = ref.watch(extensionProvider);
              final providers = _orderedMetadataProviders(extensionState);
              final selectedProviderIsAvailable = providers.any(
                (extension) => extension.id == _selectedMetadataProviderId,
              );
              final selectedId = selectedProviderIsAvailable
                  ? _selectedMetadataProviderId
                  : null;
              return _selectionField(
                label: context.l10n.editMetadataAutoFillSource,
                value: _metadataProviderName(selectedId),
                enabled: !_fetching && !_saving,
                onTap: () => _showMetadataProviderPicker(providers),
              );
            },
          ),
          Row(
            children: [
              _quickSelectButton(
                label: context.l10n.editMetadataSelectAll,
                onTap: _selectAllFields,
                cs: cs,
              ),
              const SizedBox(width: 8),
              _quickSelectButton(
                label: context.l10n.editMetadataSelectEmpty,
                onTap: _selectEmptyFields,
                cs: cs,
              ),
              const SizedBox(width: 8),
              _quickSelectButton(
                label: context.l10n.editMetadataSelectNone,
                onTap: _selectNoFields,
                cs: cs,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: _fieldDefs.keys.map((key) {
              final selected = _autoFillFields.contains(key);
              return FilterChip(
                label: Text(_fieldLabel(key)),
                selected: selected,
                onSelected: _fetching
                    ? null
                    : (val) {
                        setState(() {
                          _invalidateAutoFillPreview();
                          if (val) {
                            _autoFillFields.add(key);
                          } else {
                            _autoFillFields.remove(key);
                          }
                        });
                      },
                selectedColor: cs.primaryContainer,
                checkmarkColor: cs.onPrimaryContainer,
                labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_fetching || _saving || _autoFillFields.isEmpty)
                  ? null
                  : _fetchAutoFillPreview,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_fix_high),
              label: Text(
                _fetching
                    ? context.l10n.editMetadataAutoFillSearching
                    : context.l10n.editMetadataAutoFillFind,
              ),
            ),
          ),
          if (_autoFillPreview case final preview?) ...[
            const SizedBox(height: 12),
            _buildAutoFillPreview(cs, preview),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_fetching || _fetchingMusicBrainz || _saving)
                  ? null
                  : _fetchFromMusicBrainz,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _fetchingMusicBrainz
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.library_music_outlined),
              label: Text(context.l10n.editMetadataMusicBrainzButton),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildAutoFillPreview(ColorScheme cs, _AutoFillPreview preview) {
    final previewFields = _autoFillFields
        .where((key) {
          if (key == 'cover') return preview.coverUrl != null;
          return preview.values.containsKey(key);
        })
        .toList(growable: false);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.editMetadataAutoFillPreview(preview.sourceName),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (preview.coverPath case final coverPath?) ...[
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(coverPath),
                  width: 112,
                  height: 112,
                  fit: BoxFit.cover,
                  cacheWidth: (112 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  cacheHeight: (112 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  filterQuality: FilterQuality.low,
                  semanticLabel:
                      context.l10n.editMetadataAutoFillCoverAvailable,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
            if (preview.coverDetails case final details?) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '${details.width} × ${details.height} px · '
                  '${_formatCoverBytes(details.bytes)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
          ],
          ...previewFields.map((key) {
            final details = preview.coverDetails;
            final value = key == 'cover'
                ? details != null
                      ? '${details.width} × ${details.height} px · '
                            '${_formatCoverBytes(details.bytes)}'
                      : context.l10n.editMetadataAutoFillCoverAvailable
                : preview.values[key]!;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: Text(
                      _fieldLabel(key),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      maxLines: key == 'lyrics' ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_fetching || _saving) ? null : _applyAutoFillPreview,
              icon: const Icon(Icons.check),
              label: Text(context.l10n.editMetadataAutoFillApply),
            ),
          ),
        ],
      ),
    );
  }

  /// Fills genre and album artist from MusicBrainz (keyed by ISRC) as
  /// editable suggestions; nothing is saved until the user taps Save.
  Future<void> _fetchFromMusicBrainz() async {
    final isrc = _isrcCtrl.text.trim();
    if (isrc.isEmpty) {
      _showSheetSnackBar(context.l10n.editMetadataMusicBrainzNeedsIsrc);
      return;
    }
    setState(() => _fetchingMusicBrainz = true);
    try {
      final tags = await PlatformBridge.fetchMusicBrainzTags(
        isrc: isrc,
        albumName: _albumCtrl.text.trim(),
      );
      if (!mounted) return;
      var filled = 0;
      if (tags.genre.isNotEmpty) {
        _genreCtrl.text = tags.genre;
        filled++;
      }
      if (tags.albumArtist.isNotEmpty) {
        _albumArtistCtrl.text = tags.albumArtist;
        filled++;
      }
      _showSheetSnackBar(
        filled > 0
            ? context.l10n.editMetadataMusicBrainzFilled
            : context.l10n.editMetadataMusicBrainzNothing,
      );
    } catch (_) {
      if (mounted) {
        _showSheetSnackBar(context.l10n.editMetadataMusicBrainzNothing);
      }
    } finally {
      if (mounted) setState(() => _fetchingMusicBrainz = false);
    }
  }

  Widget _quickSelectButton({
    required String label,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return InkWell(
      onTap: _fetching ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: cs.primary),
        ),
      ),
    );
  }

  Widget _buildCoverEditor(ColorScheme cs) {
    final hasSelectedCover = _hasValue(_selectedCoverPath);
    final hasCurrentCover = _hasValue(_currentCoverPath);
    return _sectionCard(
      icon: Icons.image_outlined,
      title: context.l10n.editMetadataFieldCover,
      children: [
        if (_loadingCurrentCover)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (!hasCurrentCover && !hasSelectedCover)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              context.l10n.trackCoverNoEmbeddedArt,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _pickCoverImage,
                icon: const Icon(Icons.image_outlined),
                label: Text(
                  hasSelectedCover
                      ? context.l10n.trackCoverReplace
                      : context.l10n.trackCoverPick,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (hasSelectedCover) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.l10n.trackCoverClearSelected,
                onPressed: _saving
                    ? null
                    : () async {
                        await _cleanupSelectedCoverTemp();
                        if (!mounted) return;
                        setState(() {});
                      },
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        if (hasCurrentCover || hasSelectedCover) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (hasCurrentCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _currentCoverPath!,
                    label: context.l10n.trackCoverCurrent,
                  ),
                ),
              if (hasCurrentCover && hasSelectedCover)
                const SizedBox(width: 12),
              if (hasSelectedCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _selectedCoverPath!,
                    label:
                        _selectedCoverName ==
                            _EditMetadataSheet._onlineCoverSentinel
                        ? context.l10n.trackCoverOnline
                        : (_selectedCoverName ??
                              context.l10n.trackCoverSelected),
                  ),
                ),
            ],
          ),
          if (hasSelectedCover) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.trackCoverReplaceNotice,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          _selectionField(
            label: context.l10n.trackCoverResolution,
            value: _coverMaxDimension == null
                ? _originalCoverResolutionLabel(
                    context.l10n.trackConvertOriginal,
                  )
                : '${_coverMaxDimension!} px',
            enabled: !_saving,
            onTap: _showCoverResolutionPicker,
          ),
          Text(
            context.l10n.trackCoverResolutionHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCoverPreviewTile({
    required ColorScheme cs,
    required String path,
    required String label,
  }) {
    final details = _coverDetails[path];
    final loadingDetails = _coverDetailLoads.contains(path);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              height: 160,
              width: 160,
              fit: BoxFit.cover,
              cacheWidth: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              cacheHeight: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.broken_image,
                  color: cs.onSurfaceVariant,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        if (details != null)
          Text(
            '${details.width} × ${details.height} px · '
            '${_formatCoverBytes(details.bytes)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (loadingDetails)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary,
            ),
          ),
      ],
    );
  }

  /// Fill for input fields, one step apart from the card so each field reads as
  /// a distinct surface in light/dark/AMOLED.
  Color _fieldFill(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.05), cs.surface)
        : cs.surface;
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboard,
    int maxLines = 1,
    List<TextInputFormatter>? inputFormatters,
  }) {
    final cs = widget.colorScheme;
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          TextField(
            controller: controller,
            keyboardType: keyboard,
            inputFormatters: inputFormatters,
            maxLines: maxLines,
            cursorColor: cs.primary,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: _fieldFill(cs),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: radius,
                borderSide: BorderSide(color: cs.primary, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchField({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final cs = widget.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: _fieldFill(cs),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: SwitchListTile.adaptive(
          value: value,
          onChanged: onChanged,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          subtitle: Text(
            subtitle,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Widget _selectionField({
    required String label,
    required String value,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final cs = widget.colorScheme;
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled ? cs.onSurfaceVariant : cs.outline,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Material(
            color: _fieldFill(cs),
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: enabled ? cs.onSurface : cs.outline,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.expand_more_rounded,
                      color: enabled ? cs.onSurfaceVariant : cs.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  RoundedRectangleBorder _sectionCardShape(ColorScheme cs) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
    );
  }

  /// Titled section card. When [onHeaderTap] is set the header is a full-width
  /// tappable row (ripple clipped to the card) with an auto chevron.
  Widget _sectionCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
    VoidCallback? onHeaderTap,
    bool expanded = true,
  }) {
    final cs = widget.colorScheme;
    final collapsible = onHeaderTap != null;

    final headerRow = Row(
      children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
        if (collapsible)
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.expand_more,
              size: 22,
              color: cs.onSurfaceVariant,
            ),
          ),
      ],
    );

    final Widget header = collapsible
        ? InkWell(
            onTap: onHeaderTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: headerRow,
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: headerRow,
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: settingsGroupColor(context),
        shape: _sectionCardShape(cs),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (children.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataItem {
  final String label;
  final String value;

  _MetadataItem(this.label, this.value);
}
