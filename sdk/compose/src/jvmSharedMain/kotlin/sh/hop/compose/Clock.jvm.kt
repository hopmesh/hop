package sh.hop.compose

// JVM wall clock, shared by Android and Desktop.
internal actual fun hopNowMillis(): Long = System.currentTimeMillis()
