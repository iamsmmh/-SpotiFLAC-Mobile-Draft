package com.zarz.spotiflac

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServicePlugin
import gobackend.Gobackend
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

// SAF library-scan subsystem: tree walking, incremental diff, CUE resolution,
// and scan-progress state shared with the progress stream in MainActivity.

internal fun MainActivity.buildStableLibraryId(filePath: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
        val bytes = digest.digest(filePath.toByteArray(Charsets.UTF_8))
        val hex = bytes.joinToString("") { "%02x".format(it) }
        return "lib_$hex"
    }

internal fun MainActivity.resetSafScanProgress() {
        synchronized(safScanLock) {
            safScanProgress = MainActivity.SafScanProgress()
        }
        // Allow re-probing /proc/self/fd readability on every new scan session.
        procSelfFdReadable = null
    }

internal fun MainActivity.updateSafScanProgress(block: (MainActivity.SafScanProgress) -> Unit) {
        synchronized(safScanLock) {
            block(safScanProgress)
        }
    }

internal fun MainActivity.safProgressToJson(): String {
        val snapshot = synchronized(safScanLock) { safScanProgress.copy() }
        val obj = JSONObject()
        obj.put("total_files", snapshot.totalFiles)
        obj.put("scanned_files", snapshot.scannedFiles)
        obj.put("current_file", snapshot.currentFile)
        obj.put("error_count", snapshot.errorCount)
        obj.put("progress_pct", snapshot.progressPct)
        obj.put("is_complete", snapshot.isComplete)
        return obj.toString()
    }

internal fun MainActivity.readLibraryScanProgressJsonForStream(): String {
        return if (safScanActive) {
            safProgressToJson()
        } else {
            Gobackend.getLibraryScanProgressJSON()
        }
    }


internal fun MainActivity.loadExistingFilesFromSnapshot(snapshotPath: String): MutableMap<String, Long> {
        val result = mutableMapOf<String, Long>()
        if (snapshotPath.isBlank()) {
            return result
        }

        val snapshotFile = File(snapshotPath)
        if (!snapshotFile.exists()) {
            return result
        }

        snapshotFile.forEachLine { line ->
            if (line.isBlank()) return@forEachLine
            val separatorIndex = line.indexOf('\t')
            if (separatorIndex <= 0 || separatorIndex >= line.length - 1) {
                return@forEachLine
            }
            val modTime = line.substring(0, separatorIndex).toLongOrNull() ?: 0L
            val filePath = line.substring(separatorIndex + 1)
            if (filePath.isNotEmpty()) {
                result[filePath] = modTime
            }
        }
        return result
    }

internal fun MainActivity.resolveSafFile(treeUriStr: String, relativeDir: String, fileName: String): String {
        val obj = JSONObject()
        if (treeUriStr.isBlank() || fileName.isBlank()) {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }
        val safeRelativeDir = SafDownloadHandler.sanitizeRelativeDir(relativeDir)
        val safeFileName = SafDownloadHandler.sanitizeFilename(fileName)
        if (safeFileName.isBlank()) {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }

        val treeUri = Uri.parse(treeUriStr)
        val targetDir = SafDownloadHandler.findDocumentDir(this, treeUri, safeRelativeDir)
        if (targetDir != null) {
            val direct = targetDir.findFile(safeFileName)
            if (direct != null && direct.isFile) {
                obj.put("uri", direct.uri.toString())
                obj.put("relative_dir", safeRelativeDir)
                return obj.toString()
            }
        }

        val root = DocumentFile.fromTreeUri(this, treeUri) ?: run {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")
        var visited = 0
        val maxVisited = 20000

        while (queue.isNotEmpty()) {
            if (visited > maxVisited) break
            val (dir, path) = queue.removeFirst()
            for (child in dir.listFiles()) {
                visited++
                if (child.isDirectory) {
                    val childName = child.name ?: continue
                    val childPath = if (path.isBlank()) childName else "$path/$childName"
                    queue.add(child to childPath)
                } else if (child.isFile) {
                    if (child.name == safeFileName) {
                        obj.put("uri", child.uri.toString())
                        obj.put("relative_dir", path)
                        return obj.toString()
                    }
                }
            }
        }

        obj.put("uri", "")
        obj.put("relative_dir", "")
        return obj.toString()
    }

private data class SafFileInspectionRequest(
    val key: String,
    val treeUri: String,
    val relativeDir: String,
    val currentUri: String,
    val fileNames: List<String>,
)

/**
 * Inspects many SAF history entries while walking each document tree at most
 * once. The old per-file resolver could repeat a 20k-document breadth-first
 * search for every missing history row and every conversion filename variant.
 */
internal fun MainActivity.inspectSafFiles(requestsJson: String): String {
    val output = JSONObject()
    val resultsByKey = linkedMapOf<String, JSONObject>()
    val requests = mutableListOf<SafFileInspectionRequest>()

    fun result(
        key: String,
        status: String,
        uri: String = "",
        fileName: String = "",
        relativeDir: String = "",
    ) = JSONObject().apply {
        put("key", key)
        put("status", status)
        put("uri", uri)
        put("file_name", fileName)
        put("relative_dir", relativeDir)
    }

    try {
        val rawRequests = JSONArray(requestsJson)
        for (index in 0 until rawRequests.length()) {
            val raw = rawRequests.optJSONObject(index) ?: continue
            val key = raw.optString("key").trim()
            if (key.isBlank()) continue
            val names = mutableListOf<String>()
            val rawNames = raw.optJSONArray("file_names")
            if (rawNames != null) {
                for (nameIndex in 0 until rawNames.length()) {
                    val sanitized = SafDownloadHandler.sanitizeFilename(
                        rawNames.optString(nameIndex).trim(),
                    )
                    if (sanitized.isNotBlank() && sanitized !in names) {
                        names.add(sanitized)
                    }
                }
            }
            requests.add(
                SafFileInspectionRequest(
                    key = key,
                    treeUri = raw.optString("tree_uri").trim(),
                    relativeDir = SafDownloadHandler.sanitizeRelativeDir(
                        raw.optString("relative_dir"),
                    ),
                    currentUri = raw.optString("current_uri").trim(),
                    fileNames = names,
                ),
            )
        }

        val pendingByTree = linkedMapOf<String, MutableList<SafFileInspectionRequest>>()
        for (request in requests) {
            if (request.currentUri.startsWith("content://")) {
                try {
                    val current = DocumentFile.fromSingleUri(this, Uri.parse(request.currentUri))
                    if (current != null && current.exists() && current.isFile) {
                        resultsByKey[request.key] = result(
                            key = request.key,
                            status = "found",
                            uri = request.currentUri,
                            fileName = current.name.orEmpty(),
                            relativeDir = request.relativeDir,
                        )
                        continue
                    }
                } catch (_: Exception) {
                    // Fall through to the persisted tree lookup.
                }
            }
            if (request.treeUri.isBlank() || request.fileNames.isEmpty()) {
                resultsByKey[request.key] = result(request.key, "unknown")
                continue
            }
            pendingByTree.getOrPut(request.treeUri) { mutableListOf() }.add(request)
        }

        for ((treeUriString, treeRequests) in pendingByTree) {
            val treeUri = try {
                Uri.parse(treeUriString)
            } catch (_: Exception) {
                null
            }
            val hasPermission = treeUri != null && contentResolver.persistedUriPermissions.any {
                it.uri == treeUri && it.isReadPermission && it.isWritePermission
            }
            val root = if (hasPermission) {
                try {
                    DocumentFile.fromTreeUri(this, treeUri)
                } catch (_: Exception) {
                    null
                }
            } else {
                null
            }
            if (root == null || !root.exists() || !root.canWrite()) {
                for (request in treeRequests) {
                    resultsByKey[request.key] = result(request.key, "unknown")
                }
                continue
            }

            val unresolved = mutableListOf<SafFileInspectionRequest>()
            val directoryCache = mutableMapOf<String, Map<String, DocumentFile>>()
            val resolvedDirectoryCache = mutableMapOf<String, DocumentFile?>()
            for (request in treeRequests) {
                val directDir = if (resolvedDirectoryCache.containsKey(request.relativeDir)) {
                    resolvedDirectoryCache[request.relativeDir]
                } else {
                    val resolved = try {
                        SafDownloadHandler.findDocumentDir(this, treeUri!!, request.relativeDir)
                    } catch (_: Exception) {
                        null
                    }
                    resolvedDirectoryCache[request.relativeDir] = resolved
                    resolved
                }
                val lookup = if (directDir == null) {
                    emptyMap()
                } else {
                    getSafChildFileLookup(directDir, directoryCache)
                }
                val directName = request.fileNames.firstOrNull {
                    lookup.containsKey(it.lowercase(Locale.ROOT))
                }
                val direct = directName?.let { lookup[it.lowercase(Locale.ROOT)] }
                if (direct != null && direct.isFile) {
                    resultsByKey[request.key] = result(
                        key = request.key,
                        status = "found",
                        uri = direct.uri.toString(),
                        fileName = direct.name ?: directName,
                        relativeDir = request.relativeDir,
                    )
                } else {
                    unresolved.add(request)
                }
            }
            if (unresolved.isEmpty()) continue

            val wantedNames = unresolved
                .flatMap { it.fileNames }
                .map { it.lowercase(Locale.ROOT) }
                .toSet()
            val requestKeysByName = mutableMapOf<String, MutableSet<String>>()
            for (request in unresolved) {
                for (fileName in request.fileNames) {
                    requestKeysByName
                        .getOrPut(fileName.lowercase(Locale.ROOT)) { mutableSetOf() }
                        .add(request.key)
                }
            }
            val matches = mutableMapOf<String, Pair<DocumentFile, String>>()
            val matchedRequestKeys = mutableSetOf<String>()
            val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
            queue.add(root to "")
            var visited = 0
            val maxVisited = 50000
            var scanComplete = true

            while (queue.isNotEmpty() && matchedRequestKeys.size < unresolved.size) {
                if (visited >= maxVisited) {
                    scanComplete = false
                    break
                }
                val (directory, path) = queue.removeFirst()
                val children = try {
                    directory.listFiles()
                } catch (_: Exception) {
                    scanComplete = false
                    break
                }
                for (child in children) {
                    visited++
                    if (visited >= maxVisited) {
                        scanComplete = false
                        break
                    }
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        queue.add(child to childPath)
                    } else if (child.isFile) {
                        val childName = child.name ?: continue
                        val normalized = childName.lowercase(Locale.ROOT)
                        if (normalized in wantedNames && normalized !in matches) {
                            matches[normalized] = child to path
                            matchedRequestKeys.addAll(
                                requestKeysByName[normalized].orEmpty(),
                            )
                        }
                    }
                }
            }

            for (request in unresolved) {
                val matchedName = request.fileNames.firstOrNull {
                    matches.containsKey(it.lowercase(Locale.ROOT))
                }
                val match = matchedName?.let { matches[it.lowercase(Locale.ROOT)] }
                resultsByKey[request.key] = if (match != null) {
                    result(
                        key = request.key,
                        status = "found",
                        uri = match.first.uri.toString(),
                        fileName = match.first.name ?: matchedName,
                        relativeDir = match.second,
                    )
                } else {
                    result(request.key, if (scanComplete) "missing" else "unknown")
                }
            }
        }
    } catch (error: Exception) {
        android.util.Log.w("SpotiFLAC", "Batch SAF inspection failed: ${error.message}")
        for (request in requests) {
            resultsByKey.putIfAbsent(request.key, result(request.key, "unknown"))
        }
    }

    val results = JSONArray()
    for (request in requests) {
        results.put(resultsByKey[request.key] ?: result(request.key, "unknown"))
    }
    output.put("results", results)
    return output.toString()
}


    /**
     * Extract the audio filename referenced by a CUE sheet file.
     * Reads the FILE "name" TYPE line from the .cue text.
     * Returns just the filename (no path), or null if not found.
     */
internal fun MainActivity.extractCueAudioFileName(cueTempPath: String): String? {
        try {
            val lines = File(cueTempPath).readLines()
            for (line in lines) {
                val trimmed = line.trim().let { l ->
                    if (l.startsWith("\uFEFF")) l.removePrefix("\uFEFF").trim() else l
                }
                if (trimmed.uppercase(Locale.ROOT).startsWith("FILE ")) {
                    val rest = trimmed.substring(5).trim()
                    val filename = if (rest.startsWith("\"")) {
                        val endQuote = rest.indexOf('"', 1)
                        if (endQuote > 0) rest.substring(1, endQuote) else rest
                    } else {
                        val parts = rest.split("\\s+".toRegex())
                        if (parts.size >= 2) parts.dropLast(1).joinToString(" ") else rest
                    }
                    return filename.substringAfterLast("/").substringAfterLast("\\")
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("SpotiFLAC", "Failed to extract audio filename from CUE: ${e.message}")
        }
        return null
    }

    private val cueSiblingAudioExtensions = listOf(
        ".flac", ".wav", ".ape", ".mp3", ".ogg", ".wv", ".m4a", ".mp4", ".aac"
    )

    // Audio file extensions that the local library scanner accepts. Must stay in
    // sync with supportedAudioFormats in go_backend/library_scan.go so that every
    // format the Go engine can read (FLAC, M4A/MP4/AAC, MP3, Opus/OGG, APE/WV/MPC,
    // WAV, AIFF) is also enumerated here during the SAF folder walk. (.cue is
    // handled separately.)
    private val libraryScanAudioExtensions = setOf(
        ".flac", ".m4a", ".mp4", ".aac", ".mp3", ".opus", ".ogg",
        ".ape", ".wv", ".mpc", ".wav", ".aiff", ".aif"
    )

internal fun MainActivity.getSafChildFileLookup(
        dir: DocumentFile,
        cache: MutableMap<String, Map<String, DocumentFile>>,
    ): Map<String, DocumentFile> {
        val dirKey = dir.uri.toString()
        return cache.getOrPut(dirKey) {
            buildMap {
                for (child in listSafChildrenOrThrow(dir)) {
                    if (!child.isFile) continue
                    val childName = child.name?.trim().orEmpty()
                    if (childName.isBlank()) continue
                    put(childName.lowercase(Locale.ROOT), child)
                }
            }
        }
    }

internal fun MainActivity.resolveCueAudioSibling(
        parentDir: DocumentFile,
        cueName: String,
        audioFileName: String?,
        childLookupCache: MutableMap<String, Map<String, DocumentFile>>,
    ): DocumentFile? {
        val childLookup = getSafChildFileLookup(parentDir, childLookupCache)

        val directMatch = audioFileName
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.substringAfterLast("/")
            ?.substringAfterLast("\\")
            ?.lowercase(Locale.ROOT)
            ?.let(childLookup::get)
        if (directMatch != null) {
            return directMatch
        }

        val cueBaseName = cueName.substringBeforeLast('.').trim()
        if (cueBaseName.isBlank()) {
            return null
        }

        val cueBaseKey = cueBaseName.lowercase(Locale.ROOT)
        for (ext in cueSiblingAudioExtensions) {
            childLookup["$cueBaseKey$ext"]?.let { return it }
        }
        return null
    }

internal fun MainActivity.listSafChildrenOrThrow(dir: DocumentFile): List<DocumentFile> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            dir.uri,
            DocumentsContract.getDocumentId(dir.uri),
        )
        val cursor = contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null,
            null,
            null,
        ) ?: throw IOException("SAF provider returned no cursor for ${dir.uri}")
        return cursor.use {
            val documentIdIndex = it.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            )
            buildList {
                while (it.moveToNext()) {
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(
                        dir.uri,
                        it.getString(documentIdIndex),
                    )
                    val child = DocumentFile.fromSingleUri(this@listSafChildrenOrThrow, childUri)
                        ?: throw IOException("Invalid SAF child URI: $childUri")
                    add(child)
                }
            }
        }
    }

internal fun MainActivity.resolveReadableSafTreeOrThrow(
        treeUriStr: String,
    ): Pair<Uri, DocumentFile> {
        if (treeUriStr.isBlank()) {
            throw IllegalArgumentException("SAF tree URI is empty")
        }
        val treeUri = Uri.parse(treeUriStr)
        val hasReadPermission = contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission
        } || checkUriPermission(
            treeUri,
            android.os.Process.myPid(),
            android.os.Process.myUid(),
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasReadPermission) {
            throw SecurityException("Read access to the SAF tree has been revoked")
        }
        val root = DocumentFile.fromTreeUri(this, treeUri)
            ?: throw IOException("Unable to resolve SAF tree")
        if (!root.exists() || !root.canRead()) {
            throw IOException("SAF tree is unavailable or unreadable")
        }
        return treeUri to root
    }

internal fun MainActivity.scanSafTree(
        treeUriStr: String,
        ndjsonOutputPath: String? = null,
    ): Any {
        fun emptyResult(): Any {
            if (ndjsonOutputPath == null) return "[]"
            File(ndjsonOutputPath).writeText("", Charsets.UTF_8)
            return mapOf("path" to ndjsonOutputPath, "count" to 0)
        }

        fun cancelledResult(): Any {
            updateSafScanProgress { it.isComplete = true }
            if (ndjsonOutputPath == null) return "[]"
            try { File(ndjsonOutputPath).delete() } catch (_: Exception) {}
            throw java.util.concurrent.CancellationException("SAF library scan cancelled")
        }

        val (_, root) = resolveReadableSafTreeOrThrow(treeUriStr)

        resetSafScanProgress()
        safScanCancel = false
        safScanActive = true
        updateSafScanProgress {
            it.currentFile = "Scanning folders..."
        }

        val supportedAudioExt = libraryScanAudioExtensions
        val audioFiles = mutableListOf<Pair<DocumentFile, String>>()
        val cueFiles = mutableListOf<Pair<DocumentFile, DocumentFile>>()
        val visitedDirUris = mutableSetOf<String>()
        val safChildLookupCache = mutableMapOf<String, Map<String, DocumentFile>>()
        var traversalErrors = 0

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")

        while (queue.isNotEmpty()) {
            if (safScanCancel) {
                return cancelledResult()
            }

            val (dir, path) = queue.removeFirst()
            val dirUri = dir.uri.toString()
            if (!visitedDirUris.add(dirUri)) {
                continue
            }

            val children = try {
                listSafChildrenOrThrow(dir)
            } catch (e: Exception) {
                traversalErrors++
                updateSafScanProgress { it.errorCount = traversalErrors }
                android.util.Log.w(
                    "SpotiFLAC",
                    "SAF scan: failed listing directory $dirUri: ${e.message}",
                )
                continue
            }

            for (child in children) {
                if (safScanCancel) {
                    return cancelledResult()
                }

                try {
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        val childUri = child.uri.toString()
                        if (childUri == dirUri || visitedDirUris.contains(childUri)) {
                            continue
                        }
                        queue.add(child to childPath)
                    } else if (child.isFile) {
                        val name = child.name ?: continue
                        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                        if (ext == "cue") {
                            cueFiles.add(child to dir)
                        } else if (ext.isNotBlank() && supportedAudioExt.contains(".$ext")) {
                            audioFiles.add(child to path)
                        }
                    }
                } catch (e: Exception) {
                    traversalErrors++
                    updateSafScanProgress { it.errorCount = traversalErrors }
                    android.util.Log.w(
                        "SpotiFLAC",
                        "SAF scan: skipped child under $dirUri: ${e.message}",
                    )
                }
            }
        }

        if (traversalErrors > 0) {
            throw IOException("SAF traversal failed for $traversalErrors entries")
        }

        val totalItems = audioFiles.size + cueFiles.size
        updateSafScanProgress {
            it.totalFiles = totalItems
        }

        if (audioFiles.isEmpty() && cueFiles.isEmpty()) {
            updateSafScanProgress {
                it.isComplete = true
                it.progressPct = 100.0
            }
            return emptyResult()
        }

        // Stream results to a spill file: a full-library scan's JSONArray plus
        // its serialized string would otherwise hold the whole payload on the
        // Java heap several times over.
        val spill = if (ndjsonOutputPath == null) this.SpillJsonWriter() else null
        val ndjsonWriter = ndjsonOutputPath?.let {
            File(it).bufferedWriter(Charsets.UTF_8, 64 * 1024)
        }
        var resultCount = 0
        fun putResult(obj: JSONObject) {
            if (ndjsonWriter != null) {
                ndjsonWriter.write(obj.toString())
                ndjsonWriter.newLine()
            } else {
                spill!!.raw(if (resultCount == 0) "[" else ",")
                spill.raw(obj.toString())
            }
            resultCount++
        }
        try {
        var scanned = 0
        var errors = traversalErrors

        val cueReferencedAudioUris = mutableSetOf<String>()

        for ((cueDoc, parentDir) in cueFiles) {
            if (safScanCancel) {
                ndjsonWriter?.close()
                spill?.abandon()
                return cancelledResult()
            }

            val cueName = try { cueDoc.name ?: "" } catch (_: Exception) { "" }
            updateSafScanProgress { it.currentFile = cueName }

            var tempCuePath: String? = null
            var tempAudioPath: String? = null
            try {
                tempCuePath = copyUriToTemp(cueDoc.uri, ".cue")
                if (tempCuePath == null) {
                    errors++
                    android.util.Log.w("SpotiFLAC", "SAF scan: failed to copy CUE ${cueDoc.uri}")
                    scanned++
                    continue
                }

                val audioFileName = extractCueAudioFileName(tempCuePath)

                val audioDoc = resolveCueAudioSibling(
                    parentDir = parentDir,
                    cueName = cueName,
                    audioFileName = audioFileName,
                    childLookupCache = safChildLookupCache,
                )

                if (audioDoc == null) {
                    android.util.Log.w("SpotiFLAC", "SAF scan: no audio file found for CUE $cueName")
                    errors++
                    scanned++
                    continue
                }

                cueReferencedAudioUris.add(audioDoc.uri.toString())

                val tempDir = File(tempCuePath).parent ?: cacheDir.absolutePath
                val audioName = try { audioDoc.name ?: "audio.flac" } catch (_: Exception) { "audio.flac" }
                val audioExt = audioName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                val fallbackAudioExt = if (audioExt.isNotBlank()) ".$audioExt" else null
                val audioLastModified = try { audioDoc.lastModified() } catch (_: Exception) { cueDoc.lastModified() }
                val coverCacheKey = buildLibraryCoverCacheKey(
                    audioDoc.uri.toString(),
                    audioLastModified,
                )

                tempAudioPath = copyUriToTemp(audioDoc.uri, fallbackAudioExt)
                if (tempAudioPath == null) {
                    android.util.Log.w("SpotiFLAC", "SAF scan: failed to copy audio for CUE $cueName")
                    errors++
                    scanned++
                    continue
                }

                val renamedAudio = File(tempDir, audioName)
                val tempAudioFile = File(tempAudioPath)
                if (renamedAudio.absolutePath != tempAudioFile.absolutePath) {
                    tempAudioFile.renameTo(renamedAudio)
                    tempAudioPath = renamedAudio.absolutePath
                }

                val cueLastModified = try { cueDoc.lastModified() } catch (_: Exception) { 0L }

                val cueResultsJson = Gobackend.scanCueSheetForLibraryWithCoverCacheKey(
                    tempCuePath,
                    tempDir,
                    cueDoc.uri.toString(),
                    cueLastModified,
                    coverCacheKey,
                )

                val cueArray = JSONArray(cueResultsJson)
                for (j in 0 until cueArray.length()) {
                    putResult(cueArray.getJSONObject(j))
                }

                android.util.Log.d(
                    "SpotiFLAC",
                    "SAF scan: CUE $cueName -> ${cueArray.length()} tracks"
                )
            } catch (e: Exception) {
                errors++
                android.util.Log.w("SpotiFLAC", "SAF scan: error processing CUE $cueName: ${e.message}")
            } finally {
                try { tempCuePath?.let { File(it).delete() } } catch (_: Exception) {}
                try { tempAudioPath?.let { File(it).delete() } } catch (_: Exception) {}
            }

            scanned++
            val pct = scanned.toDouble() / totalItems.toDouble() * 100.0
            updateSafScanProgress {
                it.scannedFiles = scanned
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        for ((doc, _) in audioFiles) {
            if (safScanCancel) {
                ndjsonWriter?.close()
                spill?.abandon()
                return cancelledResult()
            }

            if (cueReferencedAudioUris.contains(doc.uri.toString())) {
                scanned++
                val pct = scanned.toDouble() / totalItems.toDouble() * 100.0
                updateSafScanProgress {
                    it.scannedFiles = scanned
                    it.progressPct = pct
                }
                continue
            }

            val name = try { doc.name ?: "" } catch (_: Exception) { "" }
            updateSafScanProgress {
                it.currentFile = name
            }

            val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            val fallbackExt = if (ext.isNotBlank()) ".${ext}" else null
            val lastModified = try { doc.lastModified() } catch (_: Exception) { 0L }
            val stableUri = doc.uri.toString()
            val coverCacheKey = buildLibraryCoverCacheKey(stableUri, lastModified)
            val metadataObj = readAudioMetadataFromUri(
                doc.uri,
                name,
                fallbackExt,
                coverCacheKey,
            )
            if (metadataObj == null) {
                errors++
            } else {
                try {
                    metadataObj.put("id", buildStableLibraryId(stableUri))
                    metadataObj.put("filePath", stableUri)
                    metadataObj.put("fileModTime", lastModified)
                    putResult(metadataObj)
                } catch (_: Exception) {
                    errors++
                }
            }

            scanned++
            val pct = scanned.toDouble() / totalItems.toDouble() * 100.0
            updateSafScanProgress {
                it.scannedFiles = scanned
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        updateSafScanProgress {
            it.isComplete = true
            it.progressPct = 100.0
        }

        if (ndjsonWriter != null) {
            ndjsonWriter.close()
            return mapOf("path" to ndjsonOutputPath, "count" to resultCount)
        }
        spill!!.raw(if (resultCount == 0) "[]" else "]")
        return spill.result()
        } catch (e: Exception) {
            try { ndjsonWriter?.close() } catch (_: Exception) {}
            spill?.abandon()
            if (ndjsonOutputPath != null) {
                try { File(ndjsonOutputPath).delete() } catch (_: Exception) {}
            }
            throw e
        }
    }

    /**
     * Incremental SAF tree scan - only scans new or modified files.
     * Supports .cue sheets: expands them into virtual track entries and
     * deduplicates audio files referenced by CUE sheets.
     * @param treeUriStr The SAF tree URI to scan
     * @param existingFilesJson JSON object mapping file URI -> lastModified timestamp
     * @return JSON object with new/changed files and removed URIs
     */
internal fun MainActivity.scanSafTreeIncremental(treeUriStr: String, existingFilesJson: String): Any {
        val existingFiles = mutableMapOf<String, Long>()
        try {
            val obj = JSONObject(existingFilesJson)
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                existingFiles[key] = obj.optLong(key, 0)
            }
        } catch (_: Exception) {}
        return scanSafTreeIncremental(treeUriStr, existingFiles)
    }

internal fun MainActivity.scanSafTreeIncremental(
        treeUriStr: String,
        existingFiles: Map<String, Long>,
    ): Any {
        val (_, root) = resolveReadableSafTreeOrThrow(treeUriStr)

        resetSafScanProgress()
        safScanCancel = false
        safScanActive = true
        updateSafScanProgress {
            it.currentFile = "Scanning folders..."
        }

        val supportedAudioExt = libraryScanAudioExtensions
        val audioFiles = mutableListOf<Triple<DocumentFile, String, Long>>()
        val cueFilesToScan = mutableListOf<Triple<DocumentFile, DocumentFile, Long>>()
        val unchangedCueFiles = mutableListOf<Pair<DocumentFile, DocumentFile>>()
        val currentUris = mutableSetOf<String>()
        val visitedDirUris = mutableSetOf<String>()
        val safChildLookupCache = mutableMapOf<String, Map<String, DocumentFile>>()
        var traversalErrors = 0

        val existingCueVirtualPaths = mutableMapOf<String, MutableList<String>>()
        for (key in existingFiles.keys) {
            val hashIdx = key.indexOf("#track")
            if (hashIdx > 0) {
                val baseCueUri = key.substring(0, hashIdx)
                existingCueVirtualPaths.getOrPut(baseCueUri) { mutableListOf() }.add(key)
            }
        }

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")

        while (queue.isNotEmpty()) {
            if (safScanCancel) {
                updateSafScanProgress { it.isComplete = true }
                val result = JSONObject()
                result.put("files", JSONArray())
                result.put("removedUris", JSONArray())
                result.put("skippedCount", 0)
                result.put("totalFiles", 0)
                result.put("cancelled", true)
                return result.toString()
            }

            val (dir, path) = queue.removeFirst()
            val dirUri = dir.uri.toString()
            if (!visitedDirUris.add(dirUri)) {
                continue
            }

            val children = try {
                listSafChildrenOrThrow(dir)
            } catch (e: Exception) {
                traversalErrors++
                updateSafScanProgress { it.errorCount = traversalErrors }
                android.util.Log.w(
                    "SpotiFLAC",
                    "SAF incremental scan: failed listing directory $dirUri: ${e.message}",
                )
                continue
            }

            for (child in children) {
                if (safScanCancel) {
                    updateSafScanProgress { it.isComplete = true }
                    val result = JSONObject()
                    result.put("files", JSONArray())
                    result.put("removedUris", JSONArray())
                    result.put("skippedCount", 0)
                    result.put("totalFiles", 0)
                    result.put("cancelled", true)
                    return result.toString()
                }

                try {
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        val childUri = child.uri.toString()
                        if (childUri == dirUri || visitedDirUris.contains(childUri)) {
                            continue
                        }
                        queue.add(child to childPath)
                    } else if (child.isFile) {
                        val uriStr = child.uri.toString()
                        currentUris.add(uriStr)

                        val name = child.name ?: continue
                        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

                        if (ext == "cue") {
                            val lastModified = try {
                                child.lastModified()
                            } catch (_: Exception) { 0L }

                            val virtualPaths = existingCueVirtualPaths[uriStr]
                            val existingModified = virtualPaths?.firstOrNull()?.let { existingFiles[it] }

                            if (existingModified != null && existingModified == lastModified) {
                                unchangedCueFiles.add(child to dir)
                                for (vp in virtualPaths) {
                                    currentUris.add(vp)
                                }
                            } else {
                                cueFilesToScan.add(Triple(child, dir, lastModified))
                            }
                        } else if (ext.isNotBlank() && supportedAudioExt.contains(".$ext")) {
                            val existingModified = existingFiles[uriStr]
                            val lastModified = try {
                                child.lastModified()
                            } catch (_: Exception) {
                                existingModified ?: 0L
                            }

                            if (existingModified == null || existingModified != lastModified) {
                                audioFiles.add(Triple(child, path, lastModified))
                            }
                        }
                    }
                } catch (e: Exception) {
                    traversalErrors++
                    updateSafScanProgress { it.errorCount = traversalErrors }
                    android.util.Log.w(
                        "SpotiFLAC",
                        "SAF incremental scan: skipped child under $dirUri: ${e.message}",
                    )
                }
            }
        }

        if (traversalErrors > 0) {
            throw IOException("SAF traversal failed for $traversalErrors entries")
        }

        val removedUris = existingFiles.keys.filter { !currentUris.contains(it) }
        val totalFiles = currentUris.size
        val filesToProcess = audioFiles.size + cueFilesToScan.size
        val skippedCount = (totalFiles - filesToProcess).coerceAtLeast(0)

        updateSafScanProgress {
            it.totalFiles = totalFiles
        }

        if (audioFiles.isEmpty() && cueFilesToScan.isEmpty()) {
            updateSafScanProgress {
                it.isComplete = true
                it.scannedFiles = totalFiles
                it.progressPct = 100.0
            }
            val result = JSONObject()
            result.put("files", JSONArray())
            result.put("removedUris", JSONArray(removedUris))
            result.put("skippedCount", skippedCount)
            result.put("totalFiles", totalFiles)
            return result.toString()
        }

        // Stream changed-file entries to a spill file — after a cache loss an
        // incremental scan can be as large as a full scan.
        val spill = this.SpillJsonWriter()
        spill.raw("{\"files\":[")
        var fileCount = 0
        fun putFile(obj: JSONObject) {
            if (fileCount > 0) spill.raw(",")
            spill.raw(obj.toString())
            fileCount++
        }
        var scanned = 0
        var errors = traversalErrors

        val cueReferencedAudioUris = mutableSetOf<String>()

        for ((cueDoc, parentDir, cueLastModified) in cueFilesToScan) {
            if (safScanCancel) {
                updateSafScanProgress { it.isComplete = true }
                spill.abandon()
                val result = JSONObject()
                result.put("files", JSONArray())
                result.put("removedUris", JSONArray())
                result.put("skippedCount", skippedCount)
                result.put("totalFiles", totalFiles)
                result.put("cancelled", true)
                return result.toString()
            }

            val cueName = try { cueDoc.name ?: "" } catch (_: Exception) { "" }
            updateSafScanProgress { it.currentFile = cueName }

            var tempCuePath: String? = null
            var tempAudioPath: String? = null
            try {
                tempCuePath = copyUriToTemp(cueDoc.uri, ".cue")
                if (tempCuePath == null) {
                    errors++
                    android.util.Log.w("SpotiFLAC", "SAF incremental scan: failed to copy CUE ${cueDoc.uri}")
                    scanned++
                    continue
                }

                val audioFileName = extractCueAudioFileName(tempCuePath)

                val audioDoc = resolveCueAudioSibling(
                    parentDir = parentDir,
                    cueName = cueName,
                    audioFileName = audioFileName,
                    childLookupCache = safChildLookupCache,
                )

                if (audioDoc == null) {
                    android.util.Log.w("SpotiFLAC", "SAF incremental scan: no audio file found for CUE $cueName")
                    errors++
                    scanned++
                    continue
                }

                cueReferencedAudioUris.add(audioDoc.uri.toString())

                val tempDir = File(tempCuePath).parent ?: cacheDir.absolutePath
                val audioName = try { audioDoc.name ?: "audio.flac" } catch (_: Exception) { "audio.flac" }
                val audioExt = audioName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                val fallbackAudioExt = if (audioExt.isNotBlank()) ".$audioExt" else null
                val audioLastModified = try { audioDoc.lastModified() } catch (_: Exception) { cueLastModified }
                val coverCacheKey = buildLibraryCoverCacheKey(
                    audioDoc.uri.toString(),
                    audioLastModified,
                )

                tempAudioPath = copyUriToTemp(audioDoc.uri, fallbackAudioExt)
                if (tempAudioPath == null) {
                    android.util.Log.w("SpotiFLAC", "SAF incremental scan: failed to copy audio for CUE $cueName")
                    errors++
                    scanned++
                    continue
                }

                val renamedAudio = File(tempDir, audioName)
                val tempAudioFile = File(tempAudioPath)
                if (renamedAudio.absolutePath != tempAudioFile.absolutePath) {
                    tempAudioFile.renameTo(renamedAudio)
                    tempAudioPath = renamedAudio.absolutePath
                }

                val cueResultsJson = Gobackend.scanCueSheetForLibraryWithCoverCacheKey(
                    tempCuePath,
                    tempDir,
                    cueDoc.uri.toString(),
                    cueLastModified,
                    coverCacheKey,
                )

                val cueArray = JSONArray(cueResultsJson)
                for (j in 0 until cueArray.length()) {
                    val trackObj = cueArray.getJSONObject(j)
                    putFile(trackObj)
                    val virtualPath = trackObj.optString("filePath", "")
                    if (virtualPath.isNotBlank()) {
                        currentUris.add(virtualPath)
                    }
                }

                android.util.Log.d(
                    "SpotiFLAC",
                    "SAF incremental scan: CUE $cueName -> ${cueArray.length()} tracks"
                )
            } catch (e: Exception) {
                errors++
                android.util.Log.w("SpotiFLAC", "SAF incremental scan: error processing CUE $cueName: ${e.message}")
            } finally {
                try { tempCuePath?.let { File(it).delete() } } catch (_: Exception) {}
                try { tempAudioPath?.let { File(it).delete() } } catch (_: Exception) {}
            }

            scanned++
            val processed = skippedCount + scanned
            val pct = if (totalFiles > 0) {
                processed.toDouble() / totalFiles.toDouble() * 100.0
            } else {
                100.0
            }
            updateSafScanProgress {
                it.scannedFiles = processed
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        for ((cueDoc, parentDir) in unchangedCueFiles) {
            var tempCue: String? = null
            try {
                tempCue = copyUriToTemp(cueDoc.uri, ".cue")
                if (tempCue != null) {
                    val audioFileName = extractCueAudioFileName(tempCue)
                    val cueName = try { cueDoc.name ?: "" } catch (_: Exception) { "" }
                    val audioDoc = resolveCueAudioSibling(
                        parentDir = parentDir,
                        cueName = cueName,
                        audioFileName = audioFileName,
                        childLookupCache = safChildLookupCache,
                    )
                    if (audioDoc != null) {
                        cueReferencedAudioUris.add(audioDoc.uri.toString())
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("SpotiFLAC", "SAF incremental scan: failed to resolve audio for unchanged CUE: ${e.message}")
            } finally {
                try { tempCue?.let { File(it).delete() } } catch (_: Exception) {}
            }
        }

        for ((doc, _, lastModified) in audioFiles) {
            if (safScanCancel) {
                updateSafScanProgress { it.isComplete = true }
                spill.abandon()
                val result = JSONObject()
                result.put("files", JSONArray())
                result.put("removedUris", JSONArray())
                result.put("skippedCount", skippedCount)
                result.put("totalFiles", totalFiles)
                result.put("cancelled", true)
                return result.toString()
            }

            if (cueReferencedAudioUris.contains(doc.uri.toString())) {
                scanned++
                val processed = skippedCount + scanned
                val pct = if (totalFiles > 0) {
                    processed.toDouble() / totalFiles.toDouble() * 100.0
                } else {
                    100.0
                }
                updateSafScanProgress {
                    it.scannedFiles = processed
                    it.progressPct = pct
                }
                continue
            }

            val name = try { doc.name ?: "" } catch (_: Exception) { "" }
            updateSafScanProgress {
                it.currentFile = name
            }

            val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            val fallbackExt = if (ext.isNotBlank()) ".${ext}" else null
            val safeLastModified = try { doc.lastModified() } catch (_: Exception) { lastModified }
            val stableUri = doc.uri.toString()
            val coverCacheKey = buildLibraryCoverCacheKey(stableUri, safeLastModified)
            val metadataObj = readAudioMetadataFromUri(
                doc.uri,
                name,
                fallbackExt,
                coverCacheKey,
            )
            if (metadataObj == null) {
                errors++
            } else {
                try {
                    metadataObj.put("id", buildStableLibraryId(stableUri))
                    metadataObj.put("filePath", stableUri)
                    metadataObj.put("fileModTime", safeLastModified)
                    metadataObj.put("lastModified", safeLastModified)
                    putFile(metadataObj)
                } catch (_: Exception) {
                    errors++
                }
            }

            scanned++
            val processed = skippedCount + scanned
            val pct = if (totalFiles > 0) {
                processed.toDouble() / totalFiles.toDouble() * 100.0
            } else {
                100.0
            }
            updateSafScanProgress {
                it.scannedFiles = processed
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        val finalRemovedUris = existingFiles.keys.filter { !currentUris.contains(it) }

        updateSafScanProgress {
            it.isComplete = true
            it.progressPct = 100.0
        }

        spill.raw("],\"removedUris\":")
        spill.raw(JSONArray(finalRemovedUris).toString())
        spill.raw(",\"skippedCount\":$skippedCount,\"totalFiles\":$totalFiles}")
        return spill.result()
    }

    /**
     * Resolve SAF file last-modified values for a list of content URIs.
     * Returns JSON object mapping uri -> lastModified (unix millis).
     */
internal fun MainActivity.getSafFileModTimes(urisJson: String): String {
        val result = JSONObject()
        val uris = try {
            JSONArray(urisJson)
        } catch (_: Exception) {
            JSONArray()
        }

        for (i in 0 until uris.length()) {
            val uriStr = uris.optString(i, "")
            if (uriStr.isBlank()) continue
            try {
                val uri = Uri.parse(uriStr)
                val doc = DocumentFile.fromSingleUri(this, uri)
                if (doc != null && doc.exists()) {
                    result.put(uriStr, doc.lastModified())
                }
            } catch (_: Exception) {}
        }

        return result.toString()
    }
