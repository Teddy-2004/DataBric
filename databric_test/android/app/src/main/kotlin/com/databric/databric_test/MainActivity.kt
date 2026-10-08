package com.databric.databric_test

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "databric/tunnel_process")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "endTunnelProcess" -> result.success(endTunnelProcess())
                    "isTunnelProcessAlive" -> result.success(tunnelPids().isNotEmpty())
                    else -> result.notImplemented()
                }
            }
    }

    // flutter_v2ray runs the Xray core in this separate process.
    private val tunnelProcessName: String get() = "$packageName:RunSoLibV2RayDaemon"

    private val pluginServices = listOf(
        "com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayProxyOnlyService",
        "com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayVPNService",
    )

    /**
     * Stopping the core does not close a reverse bridge's open connection to
     * the relay, and the core's process stays alive, so the phone keeps
     * sharing. Ending the process is what actually cuts the connection.
     *
     * The plugin's services are stopped first: they are START_STICKY, and if
     * their process died while they were still started, Android would restart
     * them with a null intent, which crashes the plugin.
     */
    private fun endTunnelProcess(): Int {
        for (service in pluginServices) {
            try {
                stopService(Intent().setClassName(packageName, service))
            } catch (e: Exception) {
            }
        }
        val pids = tunnelPids()
        for (pid in pids) {
            Process.killProcess(pid)
        }
        return pids.size
    }

    private fun tunnelPids(): Set<Int> {
        val pids = mutableSetOf<Int>()
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        am.runningAppProcesses?.forEach {
            if (it.processName == tunnelProcessName) pids.add(it.pid)
        }
        // Fallback: this app can always see its own processes in /proc.
        File("/proc").listFiles()?.forEach { dir ->
            val pid = dir.name.toIntOrNull() ?: return@forEach
            if (pid == Process.myPid()) return@forEach
            val name = try {
                File(dir, "cmdline").readText().substringBefore('\u0000')
            } catch (e: Exception) {
                return@forEach
            }
            if (name == tunnelProcessName) pids.add(pid)
        }
        return pids
    }
}
