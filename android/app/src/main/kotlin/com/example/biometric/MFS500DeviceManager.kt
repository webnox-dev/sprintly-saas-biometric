package com.example.biometric

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.app.Activity
import android.app.PendingIntent
import android.util.Log
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.hardware.usb.UsbManager
import android.hardware.usb.UsbDevice
import com.mantra.morfinauth.MorfinAuth
import com.mantra.morfinauth.MorfinAuth_Callback
import com.mantra.morfinauth.enums.DeviceDetection
import com.mantra.morfinauth.enums.DeviceModel
import com.mantra.morfinauth.DeviceInfo
import com.mantra.morfinauth.enums.ImageFormat
import com.mantra.morfinauth.enums.TemplateFormat
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.nio.ByteBuffer

class MFS500DeviceManager(
    private val context: Context,
    private val channel: MethodChannel
) : MorfinAuth_Callback {

    private var activity: Activity? = null
    
    // SDK Instance & State
    private var morfinAuth: MorfinAuth? = null
    private var deviceInfo: DeviceInfo? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isDeviceConnected = false
    
    // Threading & Synchronization
    private var initializationJob: Job? = null
    private val sdkLock = Any() // Lock for thread-safe access to morfinAuth
    
    // Manual Permission Handling
    private val ACTION_USB_PERMISSION = "com.example.biometric.USB_PERMISSION"
    private var usbPermissionReceiverRegistered = false

    companion object {
        private const val TAG = "MFS500DeviceManager"
        private const val MANTRA_VENDOR_ID = 11269 // 0x2C05
    }

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (ACTION_USB_PERMISSION == intent.action) {
                synchronized(this) {
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        if (device != null) {
                            Log.d(TAG, "Manual USB Permission GRANTED for device: " + device.deviceName)
                            // Notify Flutter which will trigger another initialize() call
                            mainHandler.post {
                                channel.invokeMethod("onDeviceAttached", mapOf("hasPermission" to true))
                            }
                        }
                    } else {
                        Log.d(TAG, "Manual USB Permission DENIED for device: " + device?.deviceName)
                    }
                }
            }
        }
    }

    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    private fun registerReceiver() {
        if (!usbPermissionReceiverRegistered) {
            val filter = IntentFilter(ACTION_USB_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(permissionReceiver, filter)
            }
            usbPermissionReceiverRegistered = true
        }
    }

    private fun unregisterReceiver() {
        if (usbPermissionReceiverRegistered) {
            try {
                context.unregisterReceiver(permissionReceiver)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering receiver: ${e.message}")
            }
            usbPermissionReceiverRegistered = false
        }
    }

    fun initialize(result: MethodChannel.Result) {
        // Cancel any pending initialization to fix race conditions from rapid attach events
        initializationJob?.cancel()

        try {
            Log.d(TAG, "Initializing MFS500 permission check...")

            // 1. Check for Mantra Device & Permission Manually
            val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
            val deviceList = manager.deviceList
            var mantraDevice: UsbDevice? = null

            for (device in deviceList.values) {
                if (device.vendorId == MANTRA_VENDOR_ID) {
                    mantraDevice = device
                    break
                }
            }

            if (mantraDevice != null) {
                if (!manager.hasPermission(mantraDevice)) {
                    Log.d(TAG, "Permission MISSING. Requesting manual permission...")
                    registerReceiver()

                    val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    } else {
                        0
                    }
                    val permissionIntent = PendingIntent.getBroadcast(
                        context, 0, Intent(ACTION_USB_PERMISSION), flag
                    )
                    manager.requestPermission(mantraDevice, permissionIntent)
                    result.error("PERMISSION_PENDING", "Requesting USB permission. Please wait.", null)
                    return
                }
            } else {
                Log.w(TAG, "No Mantra device found in USB list. Proceeding cautiously.")
            }

            // 2. Launch Background Init Job
            initializationJob = CoroutineScope(Dispatchers.IO).launch {
                try {
                    // Safe cleanup of existing instance
                    synchronized(sdkLock) {
                        if (morfinAuth != null) {
                            Log.d(TAG, "Disposing previous instance before new init...")
                            try {
                                morfinAuth!!.Uninit()
                                morfinAuth!!.Dispose()
                            } catch (e: Exception) {
                                Log.w(TAG, "Dispose warning: ${e.message}")
                            }
                            morfinAuth = null
                        }
                    }

                    // Await USB stack settlement (Crucial)
                    delay(1000) // Reduced to 1s for speed, reliance on job cancellation for safety

                    // Check for cancellation manually
                    if (!isActive) return@launch

                    // Create SDK Instance
                    val ctx = activity ?: context
                    var sdkInstance: MorfinAuth? = null
                    
                    withContext(Dispatchers.Main) {
                        try {
                            sdkInstance = MorfinAuth(ctx, this@MFS500DeviceManager)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed creating instance: ${e.message}")
                        }
                    }

                    if (!isActive) return@launch

                    if (sdkInstance == null) {
                        launch(Dispatchers.Main) {
                             result.error("INIT_FAIL", "Could not create MorfinAuth instance", null)
                        }
                        return@launch
                    }

                    synchronized(sdkLock) {
                        morfinAuth = sdkInstance
                    }

                    // Call blocking Init
                    Log.d(TAG, "Calling morfinAuth.Init() on IO Thread...")
                    val info = DeviceInfo()
                    val ret = morfinAuth!!.Init(DeviceModel.MFS500, null, info)

                    if (!isActive) {
                         Log.d(TAG, "Initialization cancelled after Init complete")
                         synchronized(sdkLock) {
                             try { morfinAuth?.Uninit(); morfinAuth?.Dispose() } catch (e: Exception) {}
                             morfinAuth = null
                         }
                         return@launch
                    }

                    withContext(Dispatchers.Main) {
                        if (ret == 0) {
                            deviceInfo = info
                            Log.d(TAG, "MFS500 device initialized successfully")
                            result.success(mapOf(
                                "success" to true,
                                "make" to info.Make,
                                "model" to info.Model,
                                "serialNo" to info.SerialNo,
                                "width" to info.Width,
                                "height" to info.Height
                            ))
                        } else {
                            val errorMsg = morfinAuth!!.GetErrorMessage(ret)
                            Log.e(TAG, "MFS500 Init Failed: $errorMsg (Code: $ret)")
                            
                            // Specific check for -2005 (timeout/not ready)
                            if (ret == -2005) {
                                 result.error("INIT_RETRY", "Device busy, retry in moment", ret)
                            } else {
                                 result.error("INIT_FAILED", errorMsg, ret)
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    Log.e(TAG, "Uncaught Init Error: ${e.message}")
                    withContext(Dispatchers.Main) {
                         result.error("INIT_EXCEPTION", e.message, null)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Init Wrapper Error: ${e.message}", e)
            result.error("INIT_LOGIC_ERROR", e.message, null)
        }
    }

    private var isCapturing = false

    fun cancelCapture(result: MethodChannel.Result?) {
        try {
            if (isCapturing) {
                Log.d(TAG, "Cancelling capture...")
                // Do NOT acquire sdkLock here — it would block the main thread
                // because captureFingerprint holds sdkLock during the blocking AutoCapture call.
                // StopCapture is designed by the Mantra SDK to safely interrupt AutoCapture
                // from any thread without needing synchronization.
                try {
                    morfinAuth?.StopCapture()
                } catch (e: Exception) {
                    Log.w(TAG, "StopCapture warning: ${e.message}")
                }
                isCapturing = false
            }
            result?.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Cancel capture error: ${e.message}")
            result?.success(false)
        }
    }

    fun captureFingerprint(result: MethodChannel.Result) {
        if (morfinAuth == null) {
            result.error("NOT_INITIALIZED", "Device not initialized", null)
            return
        }

        if (isCapturing) {
            result.success(mapOf("success" to false, "error" to "Busy"))
            return
        }

        isCapturing = true
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val minQuality = 30 // Reduced to improve acceptance rate
                val timeout = 10000 // 10s
                val quality = IntArray(1)
                val nfiq = IntArray(1)

                var ret = -1
                synchronized(sdkLock) {
                     if (morfinAuth != null) {
                         // Blocking call
                         ret = morfinAuth!!.AutoCapture(minQuality, timeout, quality, nfiq)
                     }
                }

                withContext(Dispatchers.Main) {
                    isCapturing = false
                    if (ret == 0) {
                         // Extract Template
                        val tBuffer = ByteArray(10000)
                        val tSize = IntArray(1)
                        // Extract Image
                        val iBuffer = ByteArray(500000)
                        val iSize = IntArray(1)
                        
                        synchronized(sdkLock) {
                            if (morfinAuth != null) {
                                morfinAuth!!.GetTemplate(tBuffer, tSize, TemplateFormat.FMR_V2005)
                                morfinAuth!!.GetImage(iBuffer, iSize, 1, ImageFormat.BMP)
                            }
                        }

                        result.success(mapOf(
                            "success" to true,
                            "quality" to quality[0],
                            "nfiq" to nfiq[0],
                            "isoTemplate" to tBuffer.copyOf(tSize[0]),
                            "fingerImage" to iBuffer.copyOf(iSize[0])
                        ))
                    } else {
                         val msg = morfinAuth?.GetErrorMessage(ret) ?: "Unknown"
                         result.success(mapOf("success" to false, "error" to "$msg ($ret)"))
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    isCapturing = false
                    result.error("CAPTURE_EXCEPTION", e.message, null)
                }
            }
        }
    }

    fun matchFingerprints(template1: ByteArray, template2: ByteArray, result: MethodChannel.Result) {
         CoroutineScope(Dispatchers.IO).launch {
             try {
                 val score = IntArray(1)
                 var ret = -1
                 
                 synchronized(sdkLock) {
                     if (morfinAuth != null) {
                        ret = morfinAuth!!.MatchTemplate(template1, template2, score, TemplateFormat.FMR_V2005)
                     }
                 }
                 
                 withContext(Dispatchers.Main) {
                     if (ret == 0) {
                         result.success(mapOf("matched" to (score[0] >= 1200), "score" to score[0]))
                     } else {
                         result.error("MATCH_FAIL", "Error code $ret", ret)
                     }
                 }
             } catch (e: Exception) {
                 withContext(Dispatchers.Main) { result.error("EX", e.message, null) }
             }
         }
    }

    fun cleanup(result: MethodChannel.Result?) {
        try {
            initializationJob?.cancel()
            unregisterReceiver()
            
            GlobalScope.launch(Dispatchers.IO) {
                synchronized(sdkLock) {
                    try {
                        morfinAuth?.Uninit()
                        morfinAuth?.Dispose()
                    } catch (e: Exception) {
                        Log.e(TAG, "Cleanup exception: ${e.message}")
                    }
                    morfinAuth = null
                }
            }
            
            deviceInfo = null
            isDeviceConnected = false
            Log.d(TAG, "MFS500 device cleaned up")
            result?.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "General cleanup error: ${e.message}")
            result?.error("CLEANUP_ERROR", e.message, null)
        }
    }

    // Callbacks
    override fun OnDeviceDetection(deviceName: String?, detection: DeviceDetection?) {
        Log.d(TAG, "Device Event: $detection")
        mainHandler.post {
            when (detection) {
                DeviceDetection.CONNECTED -> {
                     channel.invokeMethod("onDeviceAttached", mapOf("hasPermission" to true))
                }
                DeviceDetection.DISCONNECTED -> {
                     channel.invokeMethod("onDeviceDetached", null)
                }
                else -> {}
            }
        }
    }

    // Empty overrides
    override fun OnPreview(errorCode: Int, quality: Int, image: ByteArray?) {}
    override fun OnComplete(errorCode: Int, quality: Int, nfiq: Int) {}
    override fun OnFingerPosition(errorCode: Int, position: Int) {}
}
