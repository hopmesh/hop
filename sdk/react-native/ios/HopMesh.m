// RCT_EXTERN bridge for the Swift HopMesh module: it declares each Swift @objc method to the React
// Native bridge. Keep the selectors here in exact sync with the @objc(...) signatures in HopMesh.swift.

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(HopMesh, RCTEventEmitter)

RCT_EXTERN_METHOD(createEphemeral:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(createWithSecret:(NSString *)secretB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(openPersistent:(NSString *)dbPath
                  secret:(NSString *)secretB64
                  appSecret:(NSString *)appSecretB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(openKeyed:(NSString *)dbPath
                  key:(NSString *)keyB64
                  secret:(NSString *)secretB64
                  appSecret:(NSString *)appSecretB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(closeNode:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(address:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(secret:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setName:(NSInteger)handle
                  name:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(subscribe:(NSInteger)handle
                  topic:(NSString *)topic
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(publishPrekey:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(tick:(NSInteger)handle
                  nowMs:(double)nowMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(isPersistent:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(rehydrateDropped:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(isSecured:(NSInteger)handle
                  addr:(NSString *)addrB58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(send:(NSInteger)handle
                  to:(NSString *)toB58
                  contentType:(NSString *)contentType
                  body:(NSString *)bodyB64
                  requestAck:(BOOL)requestAck
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(sendTo:(NSInteger)handle
                  to:(NSString *)toB58
                  contentType:(NSString *)contentType
                  body:(NSString *)bodyB64
                  requestAck:(BOOL)requestAck
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(status:(NSInteger)handle
                  id:(NSString *)idB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(acceptInbox:(NSInteger)handle
                  id:(NSString *)idB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(sendServiceRequest:(NSInteger)handle
                  to:(NSString *)toB58
                  service:(NSString *)service
                  method:(NSString *)method
                  args:(NSString *)argsB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(sendServiceResponse:(NSInteger)handle
                  to:(NSString *)toB58
                  forRequestId:(NSString *)reqB64
                  status:(NSInteger)status
                  body:(NSString *)bodyB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(acceptServiceResponse:(NSInteger)handle
                  forRequestId:(NSString *)reqB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(linkUp:(NSInteger)handle
                  link:(double)link
                  role:(NSString *)role
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(linkDown:(NSInteger)handle
                  link:(double)link
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(bytesReceived:(NSInteger)handle
                  link:(double)link
                  bytes:(NSString *)bytesB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(startPump:(NSInteger)handle
                  intervalMs:(double)intervalMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stopPump:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(addressToBase58:(NSString *)bytesB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(addressFromBase58:(NSString *)text
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

+ (BOOL)requiresMainQueueSetup { return NO; }

@end
