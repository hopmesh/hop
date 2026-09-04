// The bridge contract: the exact shape of the `HopMesh` native module implemented in Kotlin
// (android/) and Swift (ios/). Every method returns a Promise; binary values cross as base64 strings
// and addresses as base58 strings (see base64.ts and the native `HopAddress` bridging). Node handles
// are opaque integers the native side mints per `HopNode`.
//
// React Native is imported LAZILY (getHopNative / getHopEmitter) so this module, and everything that
// depends only on the pure logic in node.ts, can be unit-tested under plain Node without the RN
// runtime. The classic-bridge surface here also runs on the New Architecture via the interop layer.

import { HopRelayPool } from "./types";

export interface NativeStatus {
  relayed: number;
  delivered: boolean;
  forwardHops: number;
  forwardMs: number;
}

/** A topic row as `hpsMyTopics` puts it on the wire: addresses base58, enums lowercase strings.
 *
 *  `kind` and `access` are typed as plain strings here, like `linkUp`'s `role`, because that is
 *  honestly what crosses an RN bridge: an arbitrary string the native side chose. node.ts narrows
 *  them to the public unions without rewriting an unrecognized value, so a garbage access mode fails
 *  every comparison instead of reading as `open`. */
export interface NativeHpsTopic {
  host: string;
  path: string;
  kind: string;
  hosting: boolean;
  access: string;
}

/** A discoverable topic descriptor as `hpsBrowse` puts it on the wire. */
export interface NativeHpsTopicInfo {
  host: string;
  path: string;
  kind: string;
  title: string;
  summary: string;
  access: string;
}

export interface HopNativeModule {
  // ---- node lifecycle (returns an opaque integer handle) ----
  createEphemeral(): Promise<number>;
  createWithSecret(secretB64: string): Promise<number>;
  openPersistent(dbPath: string, secretB64: string, appSecretB64: string): Promise<number>;
  openKeyed(dbPath: string, keyB64: string, secretB64: string, appSecretB64: string): Promise<number>;
  closeNode(handle: number): Promise<void>;

  // ---- identity + config ----
  address(handle: number): Promise<string>; // base58
  secret(handle: number): Promise<string>; // base64
  setName(handle: number, name: string): Promise<void>;
  subscribe(handle: number, topic: string): Promise<void>;
  publishPrekey(handle: number): Promise<boolean>;
  tick(handle: number, nowMs: number): Promise<void>;
  isPersistent(handle: number): Promise<boolean>;
  isEncrypted(handle: number): Promise<boolean>;
  rehydrateDropped(handle: number): Promise<number>;
  isSecured(handle: number, addrB58: string): Promise<boolean>;

  // ---- messaging (returns the bundle id as base64, or null on error) ----
  send(handle: number, toB58: string, contentType: string, bodyB64: string, requestAck: boolean): Promise<string | null>;
  sendTo(handle: number, toB58: string, contentType: string, bodyB64: string, requestAck: boolean): Promise<string | null>;
  status(handle: number, idB64: string): Promise<NativeStatus>;
  acceptInbox(handle: number, idB64: string): Promise<boolean>;

  // ---- hops:// request / response ----
  sendServiceRequest(handle: number, toB58: string, service: string, method: string, argsB64: string): Promise<string | null>;
  sendServiceResponse(handle: number, toB58: string, forRequestIdB64: string, status: number, bodyB64: string): Promise<boolean>;
  acceptServiceResponse(handle: number, forRequestIdB64: string): Promise<boolean>;
  acceptServiceRequest(handle: number, requestIdB64: string): Promise<boolean>;
  rejectServiceRequest(handle: number, requestIdB64: string): Promise<boolean>;

  // ---- pump: ticks, drains outbound, and polls inbox/requests/responses/hps queues, emitting events ----
  startPump(handle: number, intervalMs: number): Promise<void>;
  stopPump(handle: number): Promise<void>;

  // ---- bearer seam (drive a transport from JS) ----
  linkUp(handle: number, link: number, role: string): Promise<void>;
  linkDown(handle: number, link: number): Promise<void>;
  bytesReceived(handle: number, link: number, bytesB64: string): Promise<void>;

  // ---- section 19 relay pool ----
  relayAdd(handle: number, url: string, configured: boolean): Promise<boolean>;
  relayNext(handle: number): Promise<string | null>; // null = nothing dialable right now
  relayReport(handle: number, url: string, ok: boolean): Promise<void>;
  relayPool(handle: number): Promise<HopRelayPool>;

  // ---- hps:// pub/sub (section 32): services and channels ----
  //
  // Enums cross as lowercase strings, the same way `linkUp` carries `role`: kind is
  // "channel"|"service", access is "open"|"requestToJoin"|"invite", visibility is
  // "private"|"discoverable". A string the native side does not recognize FAILS the call. It is never
  // mapped to `open` or `channel`, because reading a garbage access mode as Open would hand a topic's
  // keys to anyone who asks.
  hpsRegister(handle: number, path: string, kind: string, access: string, visibility: string): Promise<string | null>;
  hpsSubscribe(handle: number, hostB58: string, path: string): Promise<string | null>;
  hpsPublish(handle: number, path: string, bodyB64: string): Promise<string | null>;
  acceptHpsMessage(handle: number, idB64: string): Promise<boolean>;
  hpsInvite(handle: number, path: string, destB58: string): Promise<string | null>;
  hpsAcceptInvite(handle: number, hostB58: string, path: string): Promise<string | null>;
  hpsDeclineInvite(handle: number, hostB58: string, path: string): Promise<boolean>;
  hpsLeave(handle: number, path: string): Promise<boolean>;
  hpsPending(handle: number, path: string): Promise<string[]>; // base58 requesters
  hpsApprove(handle: number, path: string, requesterB58: string): Promise<string | null>;
  hpsDeny(handle: number, path: string, requesterB58: string): Promise<boolean>;
  hpsRekey(handle: number, path: string, newPath: string, removeB58: string[]): Promise<string[]>; // base64 bundle ids
  hpsReach(handle: number, path: string): Promise<number>;
  hpsMembers(handle: number, path: string): Promise<string[]>; // base58 members
  hpsMyTopics(handle: number): Promise<NativeHpsTopic[]>;
  hpsBrowse(handle: number): Promise<NativeHpsTopicInfo[]>;

  // ---- address helpers (node-independent) ----
  addressToBase58(bytesB64: string): Promise<string>;
  addressFromBase58(text: string): Promise<string | null>; // base64, or null

  // ---- NativeEventEmitter bookkeeping (required by iOS RCTEventEmitter) ----
  addListener(eventType: string): void;
  removeListeners(count: number): void;
}

/** Event names the native pump emits over the NativeEventEmitter. */
export const HopEvent = {
  Message: "HopMesh:message",
  ServiceRequest: "HopMesh:serviceRequest",
  ServiceResponse: "HopMesh:serviceResponse",
  Outgoing: "HopMesh:outgoing",
  HpsMessage: "HopMesh:hpsMessage",
  HpsInvite: "HopMesh:hpsInvite",
} as const;

const LINK_ERROR =
  "@hop-mesh/react-native: the native HopMesh module is not linked. Rebuild the app after installing " +
  "(pod install for iOS, a Gradle sync for Android). This package requires a custom native build; it " +
  "does not run in Expo Go.";

let cachedModule: HopNativeModule | null = null;
let cachedEmitter: unknown = null;

/** Resolve the linked native module, throwing a clear error if the app was not rebuilt. */
export function getHopNative(): HopNativeModule {
  if (cachedModule) return cachedModule;
  // Lazy require so importing the pure logic never pulls in react-native.
  const { NativeModules } = require("react-native");
  const mod = NativeModules.HopMesh as HopNativeModule | undefined;
  if (!mod) throw new Error(LINK_ERROR);
  cachedModule = mod;
  return mod;
}

/** Resolve a NativeEventEmitter bound to the HopMesh module. */
export function getHopEmitter(): {
  addListener(event: string, cb: (payload: any) => void): { remove(): void };
} {
  if (cachedEmitter) return cachedEmitter as any;
  const { NativeEventEmitter } = require("react-native");
  cachedEmitter = new NativeEventEmitter(getHopNative());
  return cachedEmitter as any;
}

/** Test seam: inject a fake native module + emitter (used by the unit tests). */
export function __setHopNativeForTesting(mod: HopNativeModule | null, emitter?: any): void {
  cachedModule = mod;
  cachedEmitter = emitter ?? null;
}
