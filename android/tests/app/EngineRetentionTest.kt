package com.follow.clash

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineRetentionTest {
    @Test
    fun onlyRunningServicesRetainTheirEngine() {
        val retention = EngineRetention<Any>()
        val engine = Any()
        retention.remember(engine)
        assertTrue(retention.shouldRetain(engine, true))
        assertFalse(retention.shouldRetain(engine, false))
        assertFalse(retention.shouldRetain(null, true))
        assertSame(engine, retention.engine)
    }

    @Test
    fun explicitExitPreventsReusingAClosedCore() {
        val retention = EngineRetention<Any>()
        val engine = Any()
        retention.remember(engine)
        retention.clear()
        assertFalse(retention.shouldRetain(engine, true))
        assertNull(retention.engine)
    }

    @Test
    fun oldActivityCannotForgetReplacementEngine() {
        val retention = EngineRetention<Any>()
        val first = Any()
        val second = Any()
        retention.remember(first)
        retention.remember(second)
        retention.forget(first)
        assertSame(second, retention.engine)
        retention.forget(second)
        assertNull(retention.engine)
    }
}
