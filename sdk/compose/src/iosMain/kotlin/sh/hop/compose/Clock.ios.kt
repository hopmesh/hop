package sh.hop.compose

import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970

// iOS wall clock. NSDate's reference is the Unix epoch in seconds; scale to milliseconds.
internal actual fun hopNowMillis(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()
