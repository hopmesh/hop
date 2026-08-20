package com.hopdemo

import android.content.Intent
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate
import sh.hop.reactnative.HopDriverModule

class MainActivity : ReactActivity() {

  /**
   * Returns the name of the main component registered from JavaScript. This is used to schedule
   * rendering of the component.
   */
  override fun getMainComponentName(): String = "HopDemo"

  /**
   * Returns the instance of the [ReactActivityDelegate]. We use [DefaultReactActivityDelegate]
   * which allows you to enable New Architecture with a single boolean flags [fabricEnabled]
   */
  override fun createReactActivityDelegate(): ReactActivityDelegate =
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

  /**
   * Hands an automation URL to the Hop bridge.
   *
   * React Native's own Linking does not deliver on this stack. Measured on a release build with React
   * Native 0.87 bridgeless: an activity started by `am start -a VIEW -d hopdemo://send?...` boots the app
   * and reports its address, yet Linking.getInitialURL() yields nothing on a cold start and the warm
   * 'url' listener never fires on a redelivered intent. setIntent keeps getIntent() truthful for anything
   * reading it later, and the bridge call is what actually reaches JavaScript.
   */
  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    HopDriverModule.deliverURL(intent.dataString)
  }
}
