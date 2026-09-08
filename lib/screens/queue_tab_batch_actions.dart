part of 'queue_tab.dart';

extension _QueueTabBatchActions on _QueueTabState {
  Future<bool> _reEnrichQueueLocalTrack(
    LocalLibraryItem item, {
    required List<String> updateFields,
    required Map<String, dynamic> resolvedMetadata,
  }) async {
    final settings = ref.read(settingsProvider);
    final artistTagMode = settings.artistTagMode;
    await ref.read(settingsProvider.notifier).syncLyricsSettingsToBackend();
    final request = buildBatchReEnrichRequest(
      item: item,
      settings: settings,
      updateFields: updateFields,
      resolvedMetadata: resolvedMetadata,
    );

    final result = await PlatformBridge.reEnrichFile(request);
    final method = result['method'] as String?;
    if (method == 'native') {
      // Filesystem .lrc sidecar (SAF sidecar handled natively in Kotlin).
      await writeReEnrichSidecarLrc(
        audioFilePath: item.filePath,
        reEnrichResult: result,
      );
      return true;
    }
    if (method == 'ffmpeg') {
      return applyFfmpegReEnrichResult(
        item: item,
        result: result,
        artistTagMode: artistTagMode,
      );
    }
    return false;
  }

  List<LocalLibraryItem> _selectedFlacEligibleLocalItems(
    List<UnifiedLibraryItem> allItems,
  ) {
    final selectedItems = _selectedItemsFromAll(allItems);
    return selectedItems
        .map((item) => item.localItem)
        .whereType<LocalLibraryItem>()
        .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
        .toList(growable: false);
  }

  Future<void> _queueSelectedLocalAsFlac(
    List<UnifiedLibraryItem> allItems,
  ) async {
    final selectedLocalItems = _selectedFlacEligibleLocalItems(allItems);

    if (selectedLocalItems.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.queueFlacAction),
        content: Text(
          context.l10n.queueFlacConfirmMessage(selectedLocalItems.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.dialogCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.queueFlacAction),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final includeExtensions =
        settings.useExtensionProviders &&
        extensionState.extensions.any(
          (ext) => ext.enabled && ext.hasMetadataProvider,
        );
    final targetService = LocalTrackRedownloadService.preferredFlacService(
      settings,
      extensionState,
    );
    if (targetService.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
    final targetQuality =
        LocalTrackRedownloadService.preferredFlacQualityForService(
          targetService,
          extensionState,
        );

    final matchedTracks = <Track>[];
    var skippedCount = 0;
    final total = selectedLocalItems.length;

    var cancelled = false;
    BatchProgressDialog.show(
      context: context,
      title: context.l10n.queueFlacAction,
      total: total,
      icon: Icons.queue_music,
      onCancel: () {
        cancelled = true;
        BatchProgressDialog.dismiss(context);
      },
    );

    for (var i = 0; i < total; i++) {
      if (!mounted || cancelled) break;

      BatchProgressDialog.update(
        current: i + 1,
        detail: selectedLocalItems[i].trackName,
      );

      try {
        final resolution = await LocalTrackRedownloadService.resolveBestMatch(
          selectedLocalItems[i],
          includeExtensions: includeExtensions,
        );
        if (resolution.canQueue && resolution.match != null) {
          matchedTracks.add(resolution.match!);
        } else {
          skippedCount++;
        }
      } catch (_) {
        skippedCount++;
      }
    }

    if (!mounted) {
      return;
    }

    if (!cancelled) {
      BatchProgressDialog.dismiss(context);
    }

    if (matchedTracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.queueFlacNoReliableMatches)),
      );
      return;
    }

    ref
        .read(downloadQueueProvider.notifier)
        .addMultipleToQueue(
          matchedTracks,
          targetService,
          qualityOverride: targetQuality,
        );

    final summary = skippedCount == 0
        ? context.l10n.snackbarAddedTracksToQueue(matchedTracks.length)
        : context.l10n.queueFlacQueuedWithSkipped(
            matchedTracks.length,
            skippedCount,
          );

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(summary)));
    _setState(() {
      _selectedIds.clear();
      _isSelectionMode = false;
    });
  }

  Future<void> _reEnrichSelectedLocalFromQueue(
    List<UnifiedLibraryItem> allItems,
  ) async {
    final selectedItems = _selectedItemsFromAll(allItems);
    final selectedLocalItems = selectedItems
        .map((item) => item.localItem)
        .whereType<LocalLibraryItem>()
        .toList(growable: false);

    if (selectedLocalItems.isEmpty) {
      return;
    }

    // Hide the selection overlay: set the flag (prevents build() from
    // re-inserting via postFrameCallback) and remove the entry immediately.
    _setState(() => _isSelectionMode = false);
    _hideSelectionOverlay();

    final selection = await showReEnrichFieldDialog(
      context,
      selectedCount: selectedLocalItems.length,
    );

    if (selection == null || !mounted) {
      // Cancelled — restore selection mode; the next build cycle will
      // re-create the overlay via _syncSelectionOverlay in postFrameCallback.
      if (mounted) _setState(() => _isSelectionMode = true);
      return;
    }

    await ref.read(settingsProvider.notifier).syncLyricsSettingsToBackend();
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final previews = <BatchReEnrichPreview>[];
    var cancelled = false;
    BatchProgressDialog.show(
      context: context,
      title: context.l10n.trackReEnrichSearching,
      total: selectedLocalItems.length,
      icon: Icons.manage_search,
      onCancel: () {
        cancelled = true;
        BatchProgressDialog.dismiss(context);
      },
    );

    for (var i = 0; i < selectedLocalItems.length; i++) {
      if (!mounted || cancelled) break;
      final item = selectedLocalItems[i];
      BatchProgressDialog.update(
        current: i + 1,
        detail: '${item.trackName} - ${item.artistName}',
      );
      final updateFields = selection.updateFieldsFor(item);
      if (updateFields.isEmpty) continue;
      try {
        final result = await PlatformBridge.reEnrichFile(
          buildBatchReEnrichRequest(
            item: item,
            settings: settings,
            updateFields: updateFields,
            previewOnly: true,
          ),
        );
        final rawMetadata = result['enriched_metadata'];
        if (result['method'] != 'preview' || rawMetadata is! Map) continue;
        final enrichedMetadata = rawMetadata.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final changes = buildReEnrichMetadataChanges(
          item,
          enrichedMetadata,
          updateFields,
        );
        if (changes.isEmpty) continue;
        previews.add(
          BatchReEnrichPreview(
            item: item,
            updateFields: updateFields,
            enrichedMetadata: enrichedMetadata,
            changes: changes,
          ),
        );
      } catch (e) {
        _log.w('Skipped re-enrich preview for ${item.trackName}: $e');
      }
    }

    if (!mounted) return;
    if (!cancelled) BatchProgressDialog.dismiss(context);
    if (cancelled) {
      _setState(() => _isSelectionMode = true);
      return;
    }

    if (previews.isEmpty) {
      _setState(() => _isSelectionMode = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.trackReEnrichNoChanges)),
      );
      return;
    }

    final confirmed = await showReEnrichReviewSheet(
      context,
      previews: previews,
    );
    if (!confirmed || !mounted) {
      if (mounted) _setState(() => _isSelectionMode = true);
      return;
    }

    var successCount = 0;
    final total = previews.length;
    cancelled = false;
    BatchProgressDialog.show(
      context: context,
      title: context.l10n.trackReEnrichProgress,
      total: total,
      icon: Icons.auto_fix_high,
      onCancel: () {
        cancelled = true;
        BatchProgressDialog.dismiss(context);
      },
    );

    for (var i = 0; i < total; i++) {
      if (!mounted || cancelled) break;
      final preview = previews[i];
      BatchProgressDialog.update(
        current: i + 1,
        detail: '${preview.item.trackName} - ${preview.item.artistName}',
      );
      try {
        final ok = await _reEnrichQueueLocalTrack(
          preview.item,
          updateFields: preview.updateFields,
          resolvedMetadata: preview.enrichedMetadata,
        );
        if (ok) successCount++;
      } catch (e, stack) {
        _log.e('Re-enrich failed for ${preview.item.trackName}: $e', e, stack);
      }
    }

    if (!mounted) return;
    if (!cancelled) BatchProgressDialog.dismiss(context);

    try {
      if (!ref.read(localLibraryProvider).isScanning) {
        await ref.read(localLibraryProvider.notifier).scanAllSources();
      } else {
        await ref.read(localLibraryProvider.notifier).reloadFromStorage();
      }
    } catch (_) {
      await ref.read(localLibraryProvider.notifier).reloadFromStorage();
    }

    _exitSelectionMode();

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).clearSnackBars();
    final failedCount = total - successCount;
    final summary = failedCount <= 0
        ? '${context.l10n.trackReEnrichSuccess} ($successCount/$total)'
        : context.l10n.trackReEnrichSuccessWithFailures(
            successCount,
            total,
            failedCount,
          );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(summary)));
  }

  /// Share selected tracks via system share sheet
  Future<void> _shareSelected(List<UnifiedLibraryItem> allItems) async {
    final itemsById = {for (final item in allItems) item.id: item};
    final safUris = <String>[];
    final filesToShare = <XFile>[];

    for (final id in _selectedIds) {
      final item = itemsById[id];
      if (item == null) continue;
      final path = item.filePath;
      if (isContentUri(path)) {
        if (await fileExists(path)) safUris.add(path);
      } else if (await fileExists(path)) {
        filesToShare.add(XFile(path));
      }
    }

    if (safUris.isEmpty && filesToShare.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.selectionShareNoFiles)),
        );
      }
      return;
    }

    if (safUris.isNotEmpty) {
      try {
        if (safUris.length == 1) {
          await PlatformBridge.shareContentUri(safUris.first);
        } else {
          await PlatformBridge.shareMultipleContentUris(safUris);
        }
      } catch (e) {
        // A failed SAF share intent must not look like a successful share.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.snackbarCannotOpenFile(context.friendlyError(e)),
              ),
            ),
          );
        }
      }
    }

    if (filesToShare.isNotEmpty) {
      await SharePlus.instance.share(ShareParams(files: filesToShare));
    }
  }

  Future<void> _showBatchConvertSheet(
    BuildContext context,
    List<UnifiedLibraryItem> allItems,
  ) {
    return showBatchConvertSheet(
      context,
      ref,
      _selectedItemsFromAll(allItems),
      onExitSelectionMode: _exitSelectionMode,
      onSheetOpen: () {
        _suppressSelectionOverlay = true;
        _hideSelectionOverlay();
        _hidePlaylistSelectionOverlay();
      },
      onSheetClosed: (didStartConversion) async {
        // Wait out the sheet's exit animation before restoring the toolbar so
        // it doesn't pop in front of the still-closing sheet.
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (!mounted) {
          _suppressSelectionOverlay = false;
          return;
        }
        _suppressSelectionOverlay = false;
        if (didStartConversion) return;
        if (_isSelectionMode) {
          _syncSelectionOverlay(
            items: allItems,
            bottomPadding: MediaQuery.of(this.context).padding.bottom,
          );
        } else if (_isPlaylistSelectionMode) {
          _syncPlaylistSelectionOverlay(
            playlists: ref.read(libraryCollectionsProvider).playlists,
            bottomPadding: MediaQuery.of(this.context).padding.bottom,
          );
        }
      },
    );
  }

  Future<void> _runBatchReplayGain(List<UnifiedLibraryItem> allItems) {
    return runBatchReplayGain(
      context,
      _selectedItemsFromAll(allItems),
      onExitSelectionMode: _exitSelectionMode,
      onConfirmOpen: () {
        _suppressSelectionOverlay = true;
        _hideSelectionOverlay();
        _hidePlaylistSelectionOverlay();
      },
      onConfirmClosed: (confirmed) async {
        if (!mounted) {
          _suppressSelectionOverlay = false;
          return;
        }
        if (confirmed) {
          _suppressSelectionOverlay = false;
          return;
        }
        // Restore after the dialog's exit animation.
        await Future<void>.delayed(const Duration(milliseconds: 220));
        _suppressSelectionOverlay = false;
        if (!mounted) return;
        if (_isSelectionMode) {
          _syncSelectionOverlay(
            items: allItems,
            bottomPadding: MediaQuery.paddingOf(context).bottom,
          );
        }
      },
    );
  }
}
