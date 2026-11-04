package com.follow.clash

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineHost.retention.engine

    override fun shouldDestroyEngineWithHost(): Boolean =
        !FlutterEngineHost.retention.shouldRetain(flutterEngine, ServiceState.isRunRequested)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineHost.configure(flutterEngine)
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
