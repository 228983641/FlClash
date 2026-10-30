package com.follow.clash

internal class EngineRetention<T : Any> {
    var engine: T? = null
        private set

    fun remember(value: T) {
        engine = value
    }

    fun forget(value: T) {
        if (engine === value) engine = null
    }

    fun clear() {
        engine = null
    }

    fun shouldRetain(value: T?, runRequested: Boolean): Boolean =
        value != null && engine === value && runRequested
}
