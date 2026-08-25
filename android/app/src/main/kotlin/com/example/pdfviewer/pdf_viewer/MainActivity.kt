package com.example.pdfviewer.pdf_viewer

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Storage Access Framework bridge plus native page rasterisation.
 *
 * The Dart side previously went through `file_picker`, which copies the chosen
 * document into the app cache and hands back that path. Saving therefore wrote
 * to a throwaway copy and never touched the user's real document, and cached
 * paths in Recent Files expired when Android cleared the cache.
 *
 * SAF fixes both: `pickDocument` takes a *persistable* read/write grant on the
 * document's content URI, so the app can write back to the original file and
 * can re-open it in a later session.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "propdf/documents"
        const val REQUEST_OPEN = 4001
        const val REQUEST_CREATE = 4002
        const val PERSISTABLE_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }

    private var pendingResult: MethodChannel.Result? = null

    /** Bytes waiting to be written once ACTION_CREATE_DOCUMENT returns a URI. */
    private var pendingCreateSource: String? = null

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> onMethodCall(call, result) }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDocument" -> pickDocument(result)
            "createDocument" -> createDocument(
                call.argument<String>("name") ?: "document.pdf",
                call.argument<String>("sourcePath"),
                result
            )
            "copyToCache" -> onWorker(result) { copyToCache(call.argument<String>("uri")!!) }
            "writeDocument" -> onWorker(result) {
                writeDocument(call.argument<String>("uri")!!, call.argument<String>("sourcePath")!!)
            }
            "canWrite" -> result.success(canWrite(call.argument<String>("uri")!!))
            "displayName" -> onWorker(result) { displayName(Uri.parse(call.argument<String>("uri")!!)) }
            "releaseDocument" -> {
                releasePermission(call.argument<String>("uri")!!)
                result.success(null)
            }
            "pageCount" -> onWorker(result) { pageCount(call.argument<String>("path")!!) }
            "renderPage" -> onWorker(result) {
                renderPage(
                    call.argument<String>("path")!!,
                    call.argument<Int>("page")!!,
                    call.argument<Int>("width") ?: 160
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [block] off the platform thread and replies on it. */
    private fun <T> onWorker(result: MethodChannel.Result, block: () -> T) {
        worker.execute {
            try {
                val value = block()
                // A block with no return value yields kotlin.Unit, which the
                // method codec cannot encode -- it throws on the main thread
                // and takes the whole app down. Void replies must be null.
                val encodable = if (value is Unit) null else value
                main.post { result.success(encodable) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }

    // --- Picking -------------------------------------------------------------

    private fun pickDocument(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            addFlags(PERSISTABLE_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_OPEN)
        } catch (e: Exception) {
            pendingResult = null
            result.error("no_picker", "No document picker available.", null)
        }
    }

    private fun createDocument(name: String, sourcePath: String?, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        pendingCreateSource = sourcePath
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_TITLE, name)
            addFlags(PERSISTABLE_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_CREATE)
        } catch (e: Exception) {
            pendingResult = null
            pendingCreateSource = null
            result.error("no_picker", "No document picker available.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_OPEN && requestCode != REQUEST_CREATE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        val createSource = pendingCreateSource
        pendingResult = null
        pendingCreateSource = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // Cancelling is a normal outcome, not an error.
            result.success(null)
            return
        }

        // Survive process death and reboots so Recent Files keeps working.
        // Only the modes actually granted may be taken -- asking for WRITE on a
        // read-only provider throws, and swallowing that would leave no grant
        // at all, so the document would vanish from Recent Files next launch.
        val granted = (data?.flags ?: 0) and PERSISTABLE_FLAGS
        val toTake = if (granted != 0) granted else Intent.FLAG_GRANT_READ_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, toTake)
        } catch (_: SecurityException) {
            // Some providers refuse a persistable grant; the URI still works
            // for this session.
        }

        worker.execute {
            try {
                if (requestCode == REQUEST_CREATE && createSource != null) {
                    writeDocument(uri.toString(), createSource)
                }
                val cached = copyToCache(uri.toString())
                val payload = mapOf(
                    "uri" to uri.toString(),
                    "name" to displayName(uri),
                    "path" to cached,
                    "canWrite" to canWrite(uri.toString())
                )
                main.post { result.success(payload) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }

    // --- Reading and writing -------------------------------------------------

    /**
     * Copies the document into the cache so `SfPdfViewer` can open it as a
     * File. This is a working copy only; the content URI stays the source of
     * truth for saving.
     */
    private fun copyToCache(uriString: String): String {
        val uri = Uri.parse(uriString)
        sweepStaleCacheCopies()
        val target = File(cacheDir, "open_${System.currentTimeMillis()}.pdf")
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open $uriString" }
            target.outputStream().use { input.copyTo(it) }
        }
        return target.absolutePath
    }

    private fun writeDocument(uriString: String, sourcePath: String) {
        val uri = Uri.parse(uriString)
        val source = File(sourcePath)
        require(source.exists()) { "Nothing to write at $sourcePath" }

        // Writing goes straight at the user's real document, and "wt" truncates
        // it before a single byte of the new content lands. A failure part way
        // through would leave them with a destroyed file and no copy anywhere,
        // so keep the previous contents until the new ones are safely written.
        val rollback = File(cacheDir, "rollback_${System.currentTimeMillis()}.pdf")
        var haveRollback = false
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                rollback.outputStream().use { input.copyTo(it) }
                haveRollback = true
            }
        } catch (_: Exception) {
            // Unreadable source; there is nothing to preserve.
        }

        try {
            // "wt" truncates. Without it a shorter document leaves the tail of
            // the previous contents behind and the file is corrupt.
            contentResolver.openOutputStream(uri, "wt").use { output ->
                requireNotNull(output) { "Could not open $uriString for writing" }
                source.inputStream().use { it.copyTo(output) }
                if (output is java.io.FileOutputStream) output.fd.sync()
            }
        } catch (e: Exception) {
            if (haveRollback) {
                try {
                    contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        rollback.inputStream().use { it.copyTo(output) }
                    }
                } catch (_: Exception) {
                    throw IllegalStateException(
                        "Save failed and the original could not be restored. " +
                            "A copy of it is at ${rollback.absolutePath}",
                        e
                    )
                }
            }
            throw e
        } finally {
            if (haveRollback) rollback.delete()
        }
    }

    /**
     * Drops working copies from previous sessions.
     *
     * Every open writes a fresh `open_*.pdf`; without this they accumulate for
     * the life of the install. Only files older than a day are touched, so the
     * document currently open is never pulled out from under the viewer.
     */
    private fun sweepStaleCacheCopies() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        cacheDir.listFiles()?.forEach { file ->
            val stale = file.isFile &&
                (file.name.startsWith("open_") || file.name.startsWith("rollback_")) &&
                file.name.endsWith(".pdf") &&
                file.lastModified() < cutoff
            if (stale) file.delete()
        }
    }

    private fun canWrite(uriString: String): Boolean {
        val uri = Uri.parse(uriString)
        return contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission
        }
    }

    private fun releasePermission(uriString: String) {
        try {
            contentResolver.releasePersistableUriPermission(Uri.parse(uriString), PERSISTABLE_FLAGS)
        } catch (_: SecurityException) {
            // Already gone.
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.let { return it }
                }
            }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "document.pdf"
    }

    // --- Thumbnails ----------------------------------------------------------

    private fun pageCount(path: String): Int = withRenderer(path) { it.pageCount }

    /** Rasterises one page to a PNG at [width] logical pixels wide. */
    private fun renderPage(path: String, page: Int, width: Int): ByteArray? =
        withRenderer(path) { renderer ->
            if (page < 0 || page >= renderer.pageCount) return@withRenderer null
            renderer.openPage(page).use { pdfPage ->
                val height = (width.toFloat() * pdfPage.height / pdfPage.width).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                // PdfRenderer composites onto whatever is already there, so an
                // unpainted bitmap renders black where the page is blank.
                bitmap.eraseColor(Color.WHITE)
                pdfPage.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                bitmap.recycle()
                out.toByteArray()
            }
        }

    private fun <T> withRenderer(path: String, block: (PdfRenderer) -> T): T {
        val descriptor = ParcelFileDescriptor.open(
            File(path), ParcelFileDescriptor.MODE_READ_ONLY
        )
        return descriptor.use { fd -> PdfRenderer(fd).use { block(it) } }
    }
}
