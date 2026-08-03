// The one platform primitive the Compose SDK needs that the JVM/iOS runtimes provide differently: the
// wall clock in epoch milliseconds. The engine's tick() and every message timestamp are anchored to it.
// This is the SDK's only expect/actual: everything else stays pure commonMain behind the HopEngine seam.

package sh.hop.compose

/** Current time in milliseconds since the Unix epoch. Actuals: `System.currentTimeMillis()` on JVM,
 *  `NSDate` on iOS. Injected as the default clock in [HopClient] so tests can substitute a fake one. */
internal expect fun hopNowMillis(): Long
