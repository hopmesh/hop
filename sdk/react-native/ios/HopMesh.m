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


RCT_EXTERN_METHOD(isEncrypted:(NSInteger)handle
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


RCT_EXTERN_METHOD(acceptServiceRequest:(NSInteger)handle
                  requestId:(NSString *)reqB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(rejectServiceRequest:(NSInteger)handle
                  requestId:(NSString *)reqB64
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

// Section 19 relay pool. `configured` marks an operator or user choice a gossiped endpoint cannot
// demote, so it crosses as its own BOOL rather than being inferred from the URL.
RCT_EXTERN_METHOD(relayAdd:(NSInteger)handle
                  url:(NSString *)url
                  configured:(BOOL)configured
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(relayNext:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(relayReport:(NSInteger)handle
                  url:(NSString *)url
                  ok:(BOOL)ok
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(relayPool:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

// hps:// pub/sub (section 32). The three enums cross as lowercase NSStrings, the way `role` does; the
// Swift side rejects a string it does not recognize instead of defaulting it to a permissive value.
RCT_EXTERN_METHOD(hpsRegister:(NSInteger)handle
                  path:(NSString *)path
                  kind:(NSString *)kindText
                  access:(NSString *)accessText
                  visibility:(NSString *)visibilityText
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsSubscribe:(NSInteger)handle
                  host:(NSString *)hostB58
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsPublish:(NSInteger)handle
                  path:(NSString *)path
                  body:(NSString *)bodyB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(acceptHpsMessage:(NSInteger)handle
                  id:(NSString *)idB64
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsInvite:(NSInteger)handle
                  path:(NSString *)path
                  dest:(NSString *)destB58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsAcceptInvite:(NSInteger)handle
                  host:(NSString *)hostB58
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsDeclineInvite:(NSInteger)handle
                  host:(NSString *)hostB58
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsLeave:(NSInteger)handle
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsPending:(NSInteger)handle
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsApprove:(NSInteger)handle
                  path:(NSString *)path
                  requester:(NSString *)requesterB58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsDeny:(NSInteger)handle
                  path:(NSString *)path
                  requester:(NSString *)requesterB58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsRekey:(NSInteger)handle
                  path:(NSString *)path
                  newPath:(NSString *)newPath
                  remove:(NSArray *)removeB58
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsReach:(NSInteger)handle
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsMembers:(NSInteger)handle
                  path:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsMyTopics:(NSInteger)handle
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(hpsBrowse:(NSInteger)handle
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
