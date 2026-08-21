package com.example.biometric

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import android.app.Activity
import android.content.Context

class MFS500Plugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var deviceManager: MFS500DeviceManager? = null
    private var context: Context? = null
    private var activity: Activity? = null

    companion object {
        private const val CHANNEL_NAME = "com.example.biometric/mfs500"
        private const val TAG = "MFS500Plugin"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        context = binding.applicationContext
        // Initialize with application context, update with activity later
        deviceManager = MFS500DeviceManager(binding.applicationContext, channel)
        Log.d(TAG, "MFS500Plugin attached to engine")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        Log.d(TAG, "Method call: ${call.method}")
        
        when (call.method) {
            "initialize" -> {
                // Update activity context before init if available
                if (activity != null) {
                    deviceManager?.setActivity(activity!!)
                }
                deviceManager?.initialize(result)
            }
            
            "capture" -> deviceManager?.captureFingerprint(result)
            
            "cancelCapture" -> deviceManager?.cancelCapture(result)
            
            "match" -> {
                val template1 = call.argument<ByteArray>("template1")
                val template2 = call.argument<ByteArray>("template2")
                
                if (template1 != null && template2 != null) {
                    deviceManager?.matchFingerprints(template1, template2, result)
                } else {
                    result.error("INVALID_ARGS", "Templates cannot be null", null)
                }
            }
            
            "dispose" -> deviceManager?.cleanup(result)
            
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        deviceManager?.cleanup(null)
        deviceManager = null
        context = null
        Log.d(TAG, "MFS500Plugin detached from engine")
    }

    // --- ActivityAware Implementation ---

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        Log.d(TAG, "Attached to Activity")
        activity = binding.activity
        deviceManager?.setActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "Detached from Activity for config changes")
        activity = null
        deviceManager?.setActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        Log.d(TAG, "Reattached to Activity")
        activity = binding.activity
        deviceManager?.setActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        Log.d(TAG, "Detached from Activity")
        activity = null
        deviceManager?.setActivity(null)
    }
}
