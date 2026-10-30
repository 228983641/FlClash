package com.follow.clash

import android.content.Context
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineHost.retention.engine

    override fun shouldDestroyEngineWithHost(): Boolean =
        !FlutterEngineHost.retention.shouldRetain(flutterEngine, ServiceState.isRunRequested)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(AppPlugin::class.java)) flutterEngine.plugins.add(AppPlugin())
        if (!flutterEngine.plugins.has(BatteryPlugin::class.java)) flutterEngine.plugins.add(BatteryPlugin())
        if (!flutterEngine.plugins.has(ServicePlugin::class.java)) flutterEngine.plugins.add(ServicePlugin())
        if (!flutterEngine.plugins.has(TilePlugin::class.java)) flutterEngine.plugins.add(TilePlugin())
        FlutterEngineHost.retention.remember(flutterEngine)
        ServiceState.attachFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        if (shouldDestroyEngineWithHost()) {
            flutterEngine?.let {
                FlutterEngineHost.retention.forget(it)
                ServiceState.detachFlutterEngine(it)
            }
        }
        super.onDestroy()
    }
}
