// RCT_EXTERN bridge for the Swift HopDriverBridge module, exported to JavaScript as `HopDriver`.
// Keep the selectors here in exact sync with the @objc(...) signatures in HopDriverBridge.swift.
//
// This file is not optional plumbing. A Swift @objc method with no matching RCT_EXTERN_METHOD is
// invisible to JavaScript, and a module with no RCT_EXTERN_MODULE at all leaves NativeModules.HopDriver
// undefined, so every call resolves to nothing and the feature appears to be missing rather than
// broken. Worse, a selector that disagrees between the two files compiles cleanly and only throws when
// JavaScript actually calls it. tools/rn-bridge-lockstep-guard.py enforces exactly this for HopMesh,
// but it is hardcoded to the HopMesh trio and does not yet cover this module.

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(HopDriver, RCTEventEmitter)

RCT_EXTERN_METHOD(ensurePermissions:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(start:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setName:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(persistedName:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(savePersistedName:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(peers:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(send:(NSString *)text
                  toAddressBase58:(NSString *)addressBase58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(messages:(NSString *)peerAddressBase58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(launchURL:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(selfAddress:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(transports:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setTransportEnabled:(NSString *)transport
                  enabled:(BOOL)enabled
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
