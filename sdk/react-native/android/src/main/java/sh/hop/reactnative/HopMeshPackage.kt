// React Native package registration: exposes this SDK's native modules to the host app. Autolinking
// discovers this class via the `android.packageInstance` entry in react-native.config.js.

package sh.hop.reactnative

import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager

class HopMeshPackage : ReactPackage {
  // Two modules, deliberately. HopMesh bridges the node and link primitives, leaving the transport to
  // JavaScript; HopDriver bridges the platform driver, which owns the radios, so an app that wants the
  // real mesh (peers, Bluetooth permission, messages) uses that one.
  override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> =
    listOf(HopMeshModule(reactContext), HopDriverModule(reactContext))

  override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> =
    emptyList()
}
