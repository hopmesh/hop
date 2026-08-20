import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    window = UIWindow(frame: UIScreen.main.bounds)

    factory.startReactNative(
      withModuleName: "HopDemo",
      in: window,
      launchOptions: launchOptions
    )

    return true
  }

  /// TEST/AUTOMATION: hand an incoming `hopdemo://` URL to React Native's Linking module, so a
  /// JavaScript `Linking` listener can drive a send with `hopdemo://send?to=<base58>&text=<marker>`
  /// instead of tapping the UI. Detox cannot drive a physical iPhone, so this is how a real device
  /// becomes a SENDER rather than only an observed receiver.
  ///
  /// Info.plist declaring the scheme in CFBundleURLTypes is only half of it: without this method iOS
  /// launches or foregrounds the app and then drops the URL, so the scheme would look like a working
  /// capability while nothing consumed it. The native demo does the same job with SwiftUI's
  /// `.onOpenURL`, which is this delegate callback underneath.
  ///
  /// The COLD-launch case needs nothing extra: `RCTLinkingManager` reads the launch URL out of the
  /// bridge's launchOptions, and those are already forwarded to `startReactNative` above, so
  /// `Linking.getInitialURL()` resolves it. This method is the warm path, where the app is already
  /// running and the URL arrives as an event.
  ///
  /// `continueUserActivity` is deliberately NOT implemented. It exists for universal links, and this
  /// app declares no associated domains, so no NSUserActivity of that kind can ever arrive; the native
  /// demo does not implement it either. Adding it would be a handler for a path that cannot happen.
  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Log only routing metadata. The query carries the destination and message marker, so logging the
    // whole URL would disclose exactly what the automation bridge is meant to deliver.
    let scheme = url.scheme ?? ""
    let host = url.host ?? ""
    NSLog("HOPBRIDGE url scheme=\(scheme) host=\(host)")
    let forwarded = RCTLinkingManager.application(app, open: url, options: options)
    if !forwarded {
      NSLog("HOPBRIDGE url forward failed scheme=\(scheme) host=\(host)")
    }
    return forwarded
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
