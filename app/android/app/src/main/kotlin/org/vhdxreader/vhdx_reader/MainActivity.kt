package org.vhdxreader.vhdx_reader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pickingExport = false
    private val io = Executors.newSingleThreadExecutor()
    private val ownedHandles = ConcurrentHashMap.newKeySet<Int>()
    private external fun contextWatermark(): Long
    private external fun retireContextsBefore(before: Long): Boolean
    private external fun installVault(vault: CredentialVault)
    companion object {
        private const val PICK = 4201
        // Process ownership: activity recreation must not close a descriptor while
        // the Rust worker is duplicating it. Dart releases it after the ABI reply.
        private val descriptors = ConcurrentHashMap<Int, ParcelFileDescriptor>()
        private val nextHandle = AtomicInteger(1)
        private val createdExports = ConcurrentHashMap.newKeySet<String>()
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val nativeReady = try { System.loadLibrary("vhdx_app"); true } catch (_: UnsatisfiedLinkError) { false }
        if (nativeReady) installVault(CredentialVault(applicationContext))
        fun releaseEngineResources() {
            val watermark = if (nativeReady) contextWatermark() else 0L
            io.execute {
                if (!nativeReady || retireContextsBefore(watermark)) {
                    ownedHandles.forEach { descriptors.remove(it)?.close() }
                    ownedHandles.clear()
                }
            }
        }
        flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() { releaseEngineResources() }
            override fun onEngineWillDestroy() { releaseEngineResources() }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.vhdxreader/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeDirectory" -> result.success(applicationInfo.nativeLibraryDir)
                    "chooseImages", "chooseCredential", "createExport" -> {
                        if (pending != null) { result.error("busy", "已有文件选择窗口。", null); return@setMethodCallHandler }
                        pickingExport = call.method == "createExport"
                        val intent = Intent(if (pickingExport) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("*/*")
                        if (pickingExport) {
                            intent.type = "application/octet-stream"
                            intent.putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "export.bin")
                        } else {
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, call.method == "chooseImages")
                        }
                        pending = result
                        try { startActivityForResult(intent, PICK) }
                        catch (_: Exception) { pending = null; result.error("picker", "无法打开系统文件选择器。", null) }
                    }
                    "openDescriptor" -> io.execute {
                        var descriptor: ParcelFileDescriptor? = null
                        try {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            require(uri.scheme == "content")
                            val write = call.argument<Boolean>("write") == true
                            if (write) require(createdExports.contains(uri.toString()))
                            descriptor = contentResolver.openFileDescriptor(uri, if (write) "w" else "r")
                                ?: throw IllegalStateException()
                            if (!write) {
                                // Pipes/cloud streams without random access cannot support VHDX.
                                Os.lseek(descriptor.fileDescriptor, 0, OsConstants.SEEK_CUR)
                                require(Os.fstat(descriptor.fileDescriptor).st_size >= 0)
                            }
                            val handle = nextHandle.getAndIncrement()
                            descriptors[handle] = descriptor
                            ownedHandles.add(handle)
                            val answer = mapOf("handle" to handle, "fd" to descriptor.fd)
                            runOnUiThread { result.success(answer) }
                        } catch (_: Exception) {
                            descriptor?.close()
                            runOnUiThread { result.error("document", "无法随机读取该文件，请选择手机本地或 USB 存储中的文件。", null) }
                        }
                    }
                    "closeDescriptor" -> {
                        val handle = call.argument<Int>("handle")!!
                        ownedHandles.remove(handle)
                        descriptors.remove(handle)?.close()
                        result.success(null)
                    }
                    "removeExport" -> io.execute {
                        val uri = call.argument<String>("uri")!!
                        try {
                            require(createdExports.remove(uri))
                            require(DocumentsContract.deleteDocument(contentResolver, Uri.parse(uri)))
                            runOnUiThread { result.success(null) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("cleanup", "未完成的导出文件需要手动删除。", null) }
                        }
                    }
                    "debugDescriptorCount" -> if (BuildConfig.DEBUG) result.success(descriptors.size) else result.notImplemented()
                    else -> result.notImplemented()
                }
            }
    }
    @Deprecated("Android activity result bridge for Flutter")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK) return
        val result = pending ?: return
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) { result.success(emptyList<Any>()); return }
        val exporting = pickingExport
        val uris = (data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
            ?: listOfNotNull(data.data)).distinct()
        io.execute {
            try {
                val documents = uris.map { uri ->
                    require(uri.scheme == "content")
                    if (exporting) createdExports.add(uri.toString()) else {
                        try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                        catch (_: SecurityException) { /* Transient grants work for this session. */ }
                    }
                    var name = uri.lastPathSegment ?: "document"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst() && !it.isNull(0)) name = it.getString(0)
                    }
                    mapOf("uri" to uri.toString(), "name" to name)
                }
                runOnUiThread { result.success(documents) }
            } catch (_: Exception) { runOnUiThread { result.error("document", "无法读取所选文件的信息。", null) } }
        }
    }
    override fun onDestroy() {
        pending?.error("closed", "文件选择已取消。", null)
        pending = null
        super.onDestroy()
        io.shutdown()
    }
}
