package com.example.pdfviewer.pdf_viewer

import android.app.Activity
import android.app.SearchManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PdfWriter
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlin.math.sqrt

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
        const val REQUEST_OPEN_MANY = 4003
        const val REQUEST_TREE = 4004
        const val PERSISTABLE_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        /** Where exports land in shared storage, under Pictures or Download. */
        const val EXPORT_FOLDER = "ProPDF Studio"

        /**
         * Largest bitmap rendered in one piece. ARGB_8888 is four bytes a
         * pixel, so this is about 64 MB -- enough for a poster-sized page at
         * print resolution, small enough not to kill a low-end phone.
         */
        const val MAX_RENDER_PIXELS = 16_000_000L

        /** JPEG cannot encode either side longer than this. */
        const val MAX_JPEG_SIDE = 65_000
    }

    private var pendingResult: MethodChannel.Result? = null

    /** Bytes waiting to be written once ACTION_CREATE_DOCUMENT returns a URI. */
    private var pendingCreateSource: String? = null

    /**
     * Whether a created document is adopted: a persistable grant taken and a
     * cache copy made so it can be opened. Exports that are not PDFs the app
     * will reopen -- a .docx -- skip both rather than hoard grants.
     */
    private var pendingCreateKeep = true

    /** Files waiting to be written once ACTION_OPEN_DOCUMENT_TREE returns. */
    private var pendingExportPaths: List<String>? = null
    private var pendingExportMime: String? = null

    /**
     * A document the app was launched with, held until Dart asks for it.
     *
     * An ACTION_VIEW intent arrives in onCreate, well before the Dart entry
     * point is running, so it cannot simply be pushed over the channel.
     */
    private var launchUri: Uri? = null

    /** The type the launch intent declared for [launchUri], if it gave one. */
    private var launchType: String? = null

    private var channel: MethodChannel? = null

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .apply { setMethodCallHandler { call, result -> onMethodCall(call, result) } }
        launchUri = viewUriOf(intent)
        launchType = intent?.type
    }

    /**
     * A second document opened while the app is already running.
     *
     * The activity is singleTop, so this replaces onCreate rather than
     * starting a new instance; Dart is alive by now, so the document is
     * pushed straight over the channel.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = viewUriOf(intent) ?: return
        val type = intent.type
        worker.execute {
            try {
                val payload = describe(uri, type)
                main.post { channel?.invokeMethod("documentOpened", payload) }
            } catch (e: Exception) {
                // Nothing to open; the app simply stays where it was.
            }
        }
    }

    private fun viewUriOf(intent: Intent?): Uri? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        return intent.data
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        worker.shutdown()
        super.onDestroy()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDocument" -> pickDocument(call.argument<List<String>>("mimes"), result)
            "translateText" -> translate(call.argument<String>("text") ?: "", result)
            "webSearch" -> launch(
                Intent(Intent.ACTION_WEB_SEARCH)
                    .putExtra(SearchManager.QUERY, call.argument<String>("text") ?: ""),
                result
            )
            "htmlToPdf" -> htmlToPdf(
                call.argument<String>("html") ?: "",
                call.argument<String>("outPath")!!,
                call.argument<Boolean>("landscape") ?: false,
                call.argument<Boolean>("letter") ?: false,
                call.argument<Boolean>("margins") ?: true,
                result
            )
            "pickDocuments" -> pickDocuments(result)
            "createDocument" -> createDocument(
                call.argument<String>("name") ?: "document.pdf",
                call.argument<String>("sourcePath"),
                call.argument<String>("mime") ?: "application/pdf",
                call.argument<Boolean>("keep") ?: true,
                result
            )
            "exportFiles" -> exportFiles(
                call.argument<List<String>>("paths") ?: emptyList(),
                call.argument<String>("mime") ?: "application/octet-stream",
                call.argument<String>("target") ?: "folder",
                result
            )
            "documentInfo" -> onWorker(result) { documentInfo(Uri.parse(call.argument<String>("uri")!!)) }
            "renameDocument" -> onWorker(result) {
                renameDocument(call.argument<String>("uri")!!, call.argument<String>("name")!!)
            }
            "deleteDocument" -> onWorker(result) { deleteDocument(call.argument<String>("uri")!!) }
            "printDocument" -> {
                try {
                    printDocument(call.argument<String>("path")!!, call.argument<String>("name") ?: "Document")
                    result.success(null)
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }
            "renderPages" -> onWorker(result) {
                renderPages(
                    call.argument<String>("path")!!,
                    call.argument<List<Int>>("pages") ?: emptyList(),
                    call.argument<String>("outDir")!!,
                    call.argument<String>("baseName") ?: "page",
                    call.argument<Int>("width") ?: 1600,
                    call.argument<Double>("dpi"),
                    call.argument<String>("format") ?: "jpeg",
                    call.argument<Int>("quality") ?: 90
                )
            }
            "renderLongImage" -> onWorker(result) {
                renderLongImage(
                    call.argument<String>("path")!!,
                    call.argument<String>("outPath")!!,
                    call.argument<Int>("width") ?: 1080,
                    call.argument<Int>("quality") ?: 88
                )
            }
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "openUrl" -> launch(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!)), result)
            "viewUri" -> {
                val view = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(Uri.parse(call.argument<String>("uri")!!), call.argument<String>("mime"))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                launch(Intent.createChooser(view, null), result)
            }
            "copyToCache" -> onWorker(result) { copyToCache(call.argument<String>("uri")!!) }
            "writeDocument" -> onWorker(result) {
                writeDocument(call.argument<String>("uri")!!, call.argument<String>("sourcePath")!!)
            }
            "canWrite" -> result.success(canWrite(call.argument<String>("uri")!!))
            "consumeLaunchDocument" -> {
                val uri = launchUri
                val type = launchType
                launchUri = null
                launchType = null
                if (uri == null) {
                    result.success(null)
                } else {
                    onWorker(result) { describe(uri, type) }
                }
            }
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
                    call.argument<Int>("width") ?: 160,
                    call.argument<Int>("quality")
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun launch(intent: Intent, result: MethodChannel.Result) {
        try {
            startActivity(intent)
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("no_app", "No app on this device can open that.", null)
        }
    }

    /**
     * Hands [text] to a translation app. There is no translator in here:
     * everything this app does stays on the device, and a translation model
     * is not something it carries.
     */
    private fun translate(text: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startActivity(Intent(Intent.ACTION_TRANSLATE).putExtra(Intent.EXTRA_TEXT, text))
                result.success(null)
                return
            } catch (_: ActivityNotFoundException) {
                // Fall through to the text processors.
            }
        }
        // Translators also register as text processors, which is how the
        // system's own selection menu reaches them.
        val process = Intent(Intent.ACTION_PROCESS_TEXT).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        }
        launch(Intent.createChooser(process, "Translate with"), result)
    }

    // --- HTML to PDF ---------------------------------------------------------

    /** Held while a conversion runs, so the WebView is not collected under it. */
    private var printingWebView: WebView? = null

    /**
     * Lays [html] out on pages and writes them to [outPath].
     *
     * A WebView is the only HTML engine on the device, and its print adapter
     * the only thing that paginates it. The network stays blocked: a page is
     * rendered from what it carries, and nothing it references is fetched.
     *
     * On some WebView builds the adapter takes the page and never reports
     * back, attached to a window or not. Hence the time limit; Dart falls
     * back to its own layout when it trips.
     */
    private fun htmlToPdf(
        html: String,
        outPath: String,
        landscape: Boolean,
        letter: Boolean,
        margins: Boolean,
        result: MethodChannel.Result
    ) {
        if (printingWebView != null) {
            result.error("busy", "Another page is still being converted.", null)
            return
        }
        val webView = try {
            WebView(applicationContext)
        } catch (e: Exception) {
            result.error("no_webview", "This device has no web view to render HTML with.", null)
            return
        }
        printingWebView = webView
        var finished = false
        fun finish(error: Throwable?) {
            if (finished) return
            finished = true
            main.post {
                printingWebView = null
                webView.destroy()
                if (error == null) {
                    result.success(outPath)
                } else {
                    result.error("failed", error.message ?: "Could not convert the page.", null)
                }
            }
        }

        // Scripts stay off: the page is laid out from what it is, not from
        // what it would run.
        webView.settings.javaScriptEnabled = false
        webView.settings.blockNetworkLoads = true
        webView.settings.allowFileAccess = false
        // Nothing here may leave Dart waiting for ever.
        main.postDelayed({ finish(RuntimeException("The page took too long to render.")) }, 15_000)
        var started = false
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                // Reported more than once for some pages.
                if (started) return
                started = true
                // A beat for fonts and embedded images to settle. Through the
                // activity's handler: a view that is not attached to a window
                // only queues what is posted to it, for an attach that never
                // comes.
                main.postDelayed({
                    try {
                        val base = if (letter) PrintAttributes.MediaSize.NA_LETTER
                        else PrintAttributes.MediaSize.ISO_A4
                        val attributes = PrintAttributes.Builder()
                            .setMediaSize(if (landscape) base.asLandscape() else base.asPortrait())
                            .setResolution(PrintAttributes.Resolution("pdf", "pdf", 600, 600))
                            .setMinMargins(
                                // Thousandths of an inch.
                                if (margins) PrintAttributes.Margins(630, 700, 630, 700)
                                else PrintAttributes.Margins.NO_MARGINS
                            )
                            .build()
                        val out = ParcelFileDescriptor.open(
                            File(outPath),
                            ParcelFileDescriptor.MODE_CREATE or
                                ParcelFileDescriptor.MODE_TRUNCATE or
                                ParcelFileDescriptor.MODE_READ_WRITE
                        )
                        PdfWriter.write(view.createPrintDocumentAdapter("document"), attributes, out) { error ->
                            try {
                                out.close()
                            } catch (_: Exception) {
                            }
                            finish(error)
                        }
                    } catch (e: Throwable) {
                        finish(e)
                    }
                }, 350)
            }
        }
        webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
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

    /**
     * One document to open and keep. [mimes] widens the picker beyond PDFs,
     * for the files that are converted or handed to another editor on the
     * way in.
     */
    private fun pickDocument(mimes: List<String>?, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            if (mimes.isNullOrEmpty()) {
                type = "application/pdf"
            } else {
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
            }
            addFlags(PERSISTABLE_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_OPEN)
        } catch (e: Exception) {
            pendingResult = null
            result.error("no_picker", "No document picker available.", null)
        }
    }

    /** Several PDFs to read once, e.g. to merge. No lasting grant is taken. */
    private fun pickDocuments(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_OPEN_MANY)
        } catch (e: Exception) {
            pendingResult = null
            result.error("no_picker", "No document picker available.", null)
        }
    }

    private fun createDocument(
        name: String,
        sourcePath: String?,
        mime: String,
        keep: Boolean,
        result: MethodChannel.Result
    ) {
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        pendingCreateSource = sourcePath
        pendingCreateKeep = keep
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
            addFlags(
                if (keep) PERSISTABLE_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                else PERSISTABLE_FLAGS
            )
        }
        try {
            startActivityForResult(intent, REQUEST_CREATE)
        } catch (e: Exception) {
            pendingResult = null
            pendingCreateSource = null
            pendingCreateKeep = true
            result.error("no_picker", "No document picker available.", null)
        }
    }

    /**
     * Delivers finished files. Gallery and Downloads go through MediaStore,
     * which needs no permission from Android 10 on; anything else, or an
     * older device, goes to a folder the user picks.
     */
    private fun exportFiles(paths: List<String>, mime: String, target: String, result: MethodChannel.Result) {
        if (target == "gallery" || target == "downloads") {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.error("unsupported", "Saving there needs Android 10 or later.", null)
                return
            }
            onWorker(result) { exportToMediaStore(paths, mime, gallery = target == "gallery") }
            return
        }
        if (pendingResult != null) {
            result.error("busy", "Another document chooser is already open.", null)
            return
        }
        pendingResult = result
        pendingExportPaths = paths
        pendingExportMime = mime
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(PERSISTABLE_FLAGS)
        }
        try {
            startActivityForResult(intent, REQUEST_TREE)
        } catch (e: Exception) {
            pendingResult = null
            pendingExportPaths = null
            pendingExportMime = null
            result.error("no_picker", "No folder picker available.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_OPEN &&
            requestCode != REQUEST_CREATE &&
            requestCode != REQUEST_OPEN_MANY &&
            requestCode != REQUEST_TREE
        ) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        val createSource = pendingCreateSource
        val keep = pendingCreateKeep
        val exportPaths = pendingExportPaths
        val exportMime = pendingExportMime
        pendingResult = null
        pendingCreateSource = null
        pendingCreateKeep = true
        pendingExportPaths = null
        pendingExportMime = null
        if (result == null) return

        if (resultCode != Activity.RESULT_OK || data == null) {
            // Cancelling is a normal outcome, not an error.
            result.success(null)
            return
        }

        if (requestCode == REQUEST_OPEN_MANY) {
            val uris = mutableListOf<Uri>()
            data.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
            }
            if (uris.isEmpty()) data.data?.let { uris.add(it) }
            worker.execute {
                try {
                    // Copied now, while the picker's temporary grant holds.
                    val picked = uris.map {
                        mapOf("path" to copyToCache(it.toString()), "name" to displayName(it))
                    }
                    main.post { result.success(picked) }
                } catch (e: Exception) {
                    main.post { result.error("failed", e.message, null) }
                }
            }
            return
        }

        if (requestCode == REQUEST_TREE) {
            val tree = data.data
            if (tree == null || exportPaths == null) {
                result.success(null)
                return
            }
            onWorker(result) { exportToTree(tree, exportPaths, exportMime ?: "application/octet-stream") }
            return
        }

        val uri = data.data
        if (uri == null) {
            result.success(null)
            return
        }

        if (requestCode == REQUEST_CREATE && !keep) {
            worker.execute {
                try {
                    if (createSource != null) writeDocument(uri.toString(), createSource)
                    val payload = mapOf("uri" to uri.toString(), "name" to displayName(uri))
                    main.post { result.success(payload) }
                } catch (e: Exception) {
                    main.post { result.error("failed", e.message, null) }
                }
            }
            return
        }

        // Survive process death and reboots so Recent Files keeps working.
        // Only the modes actually granted may be taken -- asking for WRITE on a
        // read-only provider throws, and swallowing that would leave no grant
        // at all, so the document would vanish from Recent Files next launch.
        val granted = data.flags and PERSISTABLE_FLAGS
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
                val name = displayName(uri)
                val cached = copyToCache(uri.toString(), cacheExtension(name))
                val payload = mapOf(
                    "uri" to uri.toString(),
                    "name" to name,
                    "path" to cached,
                    "canWrite" to canWrite(uri.toString()),
                    "mime" to try {
                        contentResolver.getType(uri)
                    } catch (_: Exception) {
                        null
                    }
                )
                main.post { result.success(payload) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }

    /**
     * Builds the Dart-side description of a document, caching a copy for the
     * viewer to render.
     *
     * A VIEW intent carries a one-shot grant, so the persistable upgrade is
     * attempted and allowed to fail: the document still opens for this
     * session, it just reports itself as not writable, which is what makes the
     * editor steer the user to Save a copy instead of writing nowhere.
     *
     * The app is offered for more than PDFs, so [type] -- what the sending
     * app called the file -- travels with it. Dart decides what the file
     * really is from its contents; this is only a hint for the cases the
     * contents cannot settle.
     */
    private fun describe(uri: Uri, type: String?): Map<String, Any?> {
        try {
            contentResolver.takePersistableUriPermission(uri, PERSISTABLE_FLAGS)
        } catch (_: SecurityException) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: SecurityException) {
                // Temporary grant only; good for this session.
            }
        }
        val name = displayName(uri)
        val mime = type ?: try {
            contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "path" to copyToCache(uri.toString(), cacheExtension(name)),
            "canWrite" to canWrite(uri.toString()),
            "mime" to mime
        )
    }

    /**
     * The extension for a cache copy: the file's own where it has a plain
     * one, so that a Word file or a photo is not left lying about labelled
     * as a PDF, and `pdf` for a name that carries none.
     */
    private fun cacheExtension(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return if (Regex("[a-z0-9]{1,5}").matches(extension)) extension else "pdf"
    }

    // --- Reading and writing -------------------------------------------------

    /**
     * Copies the document into the cache so `SfPdfViewer` can open it as a
     * File. This is a working copy only; the content URI stays the source of
     * truth for saving.
     */
    private fun copyToCache(uriString: String, extension: String = "pdf"): String {
        val uri = Uri.parse(uriString)
        sweepStaleCacheCopies()
        // A unique name: several documents picked at once are copied within
        // the same millisecond.
        val target = File.createTempFile("open_", ".$extension", cacheDir)
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
     * Every open writes a fresh `open_*` copy; without this they accumulate
     * for the life of the install. Only files older than a day are touched, so
     * the document currently open is never pulled out from under the viewer.
     * The prefix alone identifies them: a copy of something handed over by
     * another app keeps that file's extension, not `.pdf`.
     */
    private fun sweepStaleCacheCopies() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        cacheDir.listFiles()?.forEach { file ->
            val stale = file.isFile &&
                (file.name.startsWith("open_") || file.name.startsWith("rollback_")) &&
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

    // --- Managing the document itself ---------------------------------------

    /** Size, date, a readable location and what the provider allows. */
    private fun documentInfo(uri: Uri): Map<String, Any?> {
        var size: Long? = null
        var modified: Long? = null
        var flags = 0
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                    val dateIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    if (dateIndex >= 0 && !cursor.isNull(dateIndex)) modified = cursor.getLong(dateIndex)
                    val flagIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                    if (flagIndex >= 0 && !cursor.isNull(flagIndex)) flags = cursor.getInt(flagIndex)
                }
            }
        } catch (_: Exception) {
            // Some providers answer only the openable columns; the rest stay unknown.
        }
        val isDocument = DocumentsContract.isDocumentUri(this, uri)
        return mapOf(
            "size" to size,
            "modified" to modified,
            "location" to readableLocation(uri),
            "canRename" to (isDocument && flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0),
            "canDelete" to (isDocument && flags and DocumentsContract.Document.FLAG_SUPPORTS_DELETE != 0)
        )
    }

    /**
     * A location a person can read. Local storage encodes the real path in
     * the document ID; anything else is described by the app that holds it.
     */
    private fun readableLocation(uri: Uri): String? {
        val authority = uri.authority ?: return uri.path
        if (DocumentsContract.isDocumentUri(this, uri)) {
            val id = DocumentsContract.getDocumentId(uri)
            when (authority) {
                "com.android.externalstorage.documents" -> {
                    val volume = id.substringBefore(':')
                    val relative = id.substringAfter(':', "")
                    val root = if (volume.equals("primary", ignoreCase = true)) {
                        "/storage/emulated/0"
                    } else {
                        "/storage/$volume"
                    }
                    return if (relative.isEmpty()) root else "$root/$relative"
                }
                "com.android.providers.downloads.documents" ->
                    if (id.startsWith("raw:")) return id.removePrefix("raw:")
            }
        }
        return try {
            packageManager.resolveContentProvider(authority, 0)
                ?.loadLabel(packageManager)?.toString() ?: authority
        } catch (_: Exception) {
            authority
        }
    }

    private fun renameDocument(uriString: String, name: String): Map<String, Any?> {
        val uri = Uri.parse(uriString)
        if (!DocumentsContract.isDocumentUri(this, uri)) {
            throw IllegalStateException("This file cannot be renamed from here.")
        }
        val renamed = DocumentsContract.renameDocument(contentResolver, uri, name)
            ?: throw IllegalStateException("The app holding this file refused to rename it.")
        if (renamed != uri) {
            // Providers that encode the name in the ID hand back a new URI and
            // move the caller's grant onto it. Make it last, if allowed.
            try {
                contentResolver.takePersistableUriPermission(renamed, PERSISTABLE_FLAGS)
            } catch (_: SecurityException) {
                try {
                    contentResolver.takePersistableUriPermission(renamed, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: SecurityException) {
                    // Good for this session only.
                }
            }
            releasePermission(uriString)
        }
        val writable = canWrite(renamed.toString()) ||
            checkCallingOrSelfUriPermission(renamed, Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED
        return mapOf(
            "uri" to renamed.toString(),
            "name" to displayName(renamed),
            "canWrite" to writable
        )
    }

    private fun deleteDocument(uriString: String): Boolean {
        val uri = Uri.parse(uriString)
        val deleted = if (DocumentsContract.isDocumentUri(this, uri)) {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } else {
            contentResolver.delete(uri, null, null) > 0
        }
        if (deleted) releasePermission(uriString)
        return deleted
    }

    /** Hands the file to the system print dialog, which does the rest. */
    private fun printDocument(path: String, name: String) {
        val file = File(path)
        require(file.exists()) { "Nothing to print at $path" }
        val manager = getSystemService(Context.PRINT_SERVICE) as PrintManager
        manager.print(name, object : PrintDocumentAdapter() {
            override fun onLayout(
                oldAttributes: PrintAttributes?,
                newAttributes: PrintAttributes?,
                cancellationSignal: CancellationSignal?,
                callback: LayoutResultCallback,
                extras: Bundle?
            ) {
                if (cancellationSignal?.isCanceled == true) {
                    callback.onLayoutCancelled()
                    return
                }
                val info = PrintDocumentInfo.Builder(name)
                    .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                    .build()
                callback.onLayoutFinished(info, true)
            }

            override fun onWrite(
                pages: Array<out PageRange>?,
                destination: ParcelFileDescriptor,
                cancellationSignal: CancellationSignal?,
                callback: WriteResultCallback
            ) {
                try {
                    // Every page is written; the spooler picks out the range
                    // the user asked for.
                    FileInputStream(file).use { input ->
                        FileOutputStream(destination.fileDescriptor).use { input.copyTo(it) }
                    }
                    if (cancellationSignal?.isCanceled == true) {
                        callback.onWriteCancelled()
                    } else {
                        callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                    }
                } catch (e: Exception) {
                    callback.onWriteFailed(e.message)
                }
            }
        }, null)
    }

    // --- Exporting -----------------------------------------------------------

    private fun exportToTree(tree: Uri, paths: List<String>, mime: String): Int {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree)
        )
        var written = 0
        for (path in paths) {
            val source = File(path)
            val target = DocumentsContract.createDocument(
                contentResolver,
                parent,
                mimeFor(source.name, mime),
                source.name
            ) ?: continue
            contentResolver.openOutputStream(target, "w")?.use { output ->
                source.inputStream().use { it.copyTo(output) }
                written++
            }
        }
        return written
    }

    private fun exportToMediaStore(paths: List<String>, mime: String, gallery: Boolean): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Saving there needs Android 10 or later.")
        }
        val collection = if (gallery) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val folder = (if (gallery) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_DOWNLOADS) +
            "/" + EXPORT_FOLDER
        var written = 0
        for (path in paths) {
            val source = File(path)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeFor(source.name, mime))
                put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
                // Hidden from other apps until the bytes are all there.
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val item = contentResolver.insert(collection, values) ?: continue
            try {
                contentResolver.openOutputStream(item)!!.use { output ->
                    source.inputStream().use { it.copyTo(output) }
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(item, values, null, null)
                written++
            } catch (e: Exception) {
                contentResolver.delete(item, null, null)
                throw e
            }
        }
        return written
    }

    /** The file's own type where its extension says, [fallback] otherwise. */
    private fun mimeFor(name: String, fallback: String): String =
        when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "pdf" -> "application/pdf"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "txt" -> "text/plain"
            else -> fallback
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

    /**
     * Rasterises one page at [width] pixels wide: PNG, or JPEG at [quality]
     * when one is given.
     */
    private fun renderPage(path: String, page: Int, width: Int, quality: Int?): ByteArray? =
        withRenderer(path) { renderer ->
            if (page < 0 || page >= renderer.pageCount) return@withRenderer null
            renderer.openPage(page).use { pdfPage ->
                val bitmap = renderToBitmap(pdfPage, width)
                val out = ByteArrayOutputStream()
                if (quality != null) {
                    bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                } else {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                bitmap.recycle()
                out.toByteArray()
            }
        }

    /**
     * Renders [pages] to numbered files in [outDir], each [width] pixels wide
     * or, with [dpi], at that resolution of its physical size.
     */
    private fun renderPages(
        path: String,
        pages: List<Int>,
        outDir: String,
        baseName: String,
        width: Int,
        dpi: Double?,
        format: String,
        quality: Int
    ): List<String> = withRenderer(path) { renderer ->
        val directory = File(outDir).apply { mkdirs() }
        val jpeg = format != "png"
        val extension = if (jpeg) "jpg" else "png"
        val digits = renderer.pageCount.toString().length
        pages.filter { it in 0 until renderer.pageCount }.map { index ->
            renderer.openPage(index).use { pdfPage ->
                // PdfRenderer reports page size in points (1/72 inch).
                val pixels = if (dpi != null) (pdfPage.width * dpi / 72.0).roundToInt() else width
                val bitmap = renderToBitmap(pdfPage, pixels)
                val number = (index + 1).toString().padStart(digits, '0')
                val out = File(directory, "${baseName}_$number.$extension")
                FileOutputStream(out).use {
                    bitmap.compress(
                        if (jpeg) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG,
                        quality,
                        it
                    )
                }
                bitmap.recycle()
                out.absolutePath
            }
        }
    }

    /**
     * Stitches every page into one tall JPEG, with a thin gap between pages.
     *
     * The strip is held in RGB_565 (two bytes a pixel) and its width shrunk
     * until it fits the memory budget and JPEG's size limit, so a long
     * document still produces an image rather than an out-of-memory crash.
     */
    private fun renderLongImage(path: String, outPath: String, width: Int, quality: Int): String =
        withRenderer(path) { renderer ->
            val count = renderer.pageCount
            require(count > 0) { "The document has no pages." }
            val gap = 12
            val ratios = DoubleArray(count) { i ->
                renderer.openPage(i).use { it.height.toDouble() / it.width }
            }
            fun heightAt(w: Int): Int = ratios.sumOf { (w * it).roundToInt().coerceAtLeast(1) } + gap * (count - 1)

            // 3000 wide keeps an A4 page under MAX_RENDER_PIXELS, so every
            // page renders at exactly the strip width.
            var w = width.coerceIn(200, 3000)
            val budget = 40_000_000L
            while (w > 200 && (w.toLong() * heightAt(w) > budget || heightAt(w) > MAX_JPEG_SIDE)) {
                w = (w * 0.85).toInt().coerceAtLeast(200)
            }
            val height = heightAt(w)
            require(height <= MAX_JPEG_SIDE) { "This document is too long for a single image." }

            val sheet = Bitmap.createBitmap(w, height, Bitmap.Config.RGB_565)
            try {
                val canvas = Canvas(sheet)
                canvas.drawColor(Color.rgb(224, 224, 224))
                var top = 0
                for (i in 0 until count) {
                    renderer.openPage(i).use { pdfPage ->
                        val bitmap = renderToBitmap(pdfPage, w)
                        canvas.drawBitmap(bitmap, 0f, top.toFloat(), null)
                        top += bitmap.height + gap
                        bitmap.recycle()
                    }
                }
                val out = File(outPath).apply { parentFile?.mkdirs() }
                FileOutputStream(out).use { sheet.compress(Bitmap.CompressFormat.JPEG, quality, it) }
                out.absolutePath
            } finally {
                sheet.recycle()
            }
        }

    /**
     * Renders [pdfPage] onto a white bitmap [width] pixels wide, shrunk if
     * the page would otherwise exceed [MAX_RENDER_PIXELS].
     */
    private fun renderToBitmap(pdfPage: PdfRenderer.Page, width: Int): Bitmap {
        var w = width.coerceIn(16, 8000)
        var h = (w.toDouble() * pdfPage.height / pdfPage.width).roundToInt().coerceAtLeast(1)
        val pixels = w.toLong() * h
        if (pixels > MAX_RENDER_PIXELS) {
            val shrink = sqrt(MAX_RENDER_PIXELS.toDouble() / pixels)
            w = (w * shrink).toInt().coerceAtLeast(1)
            h = (h * shrink).toInt().coerceAtLeast(1)
        }
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        // PdfRenderer composites onto whatever is already there, so an
        // unpainted bitmap renders black where the page is blank.
        bitmap.eraseColor(Color.WHITE)
        pdfPage.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        return bitmap
    }

    private fun <T> withRenderer(path: String, block: (PdfRenderer) -> T): T {
        val descriptor = ParcelFileDescriptor.open(
            File(path), ParcelFileDescriptor.MODE_READ_ONLY
        )
        return descriptor.use { fd -> PdfRenderer(fd).use { block(it) } }
    }
}
