package com.follow.clash

import com.follow.clash.common.GlobalState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

internal object FlutterEngineHost {
    val retention = EngineRetention<FlutterEngine>()

    fun configure(engine: FlutterEngine) {
        if (!engine.plugins.has(AppPlugin::class.java)) engine.plugins.add(AppPlugin())
        if (!engine.plugins.has(BatteryPlugin::class.java)) engine.plugins.add(BatteryPlugin())
        if (!engine.plugins.has(ServicePlugin::class.java)) engine.plugins.add(ServicePlugin())
        if (!engine.plugins.has(TilePlugin::class.java)) engine.plugins.add(TilePlugin())
        retention.remember(engine)
        ServiceState.attachFlutterEngine(engine)
    }

    fun ensureRunning() {
        if (retention.engine != null) return
        val engine = FlutterEngine(GlobalState.application)
        try {
            configure(engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
                listOf("--background-service"),
            )
            GlobalState.log("[SA] background-engine-started")
        } catch (error: Exception) {
            retention.forget(engine)
            ServiceState.detachFlutterEngine(engine)
            engine.destroy()
            throw error
        }
    }
}
