// The bridge contract: the exact shape of the `HopMesh` native module implemented in Kotlin
// (android/) and Swift (ios/). Every method returns a Promise; binary values cross as base64 strings
// and addresses as base58 strings (see base64.ts and the native `HopAddress` bridging). Node handles
// are opaque integers the native side mints per `HopNode`.
//
// React Native is imported LAZILY (getHopNative / getHopEmitter) so this module, and everything that
// depends only on the pure logic in node.ts, can be unit-tested under plain Node without the RN
// runtime. The classic-bridge surface here also runs on the New Architecture via the interop layer.

export interface NativeStatus {
  relayed: number;
  delivered: boolean;
  forwardHops: number;
  forwardMs: number;
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

  // ---- pump: ticks, drains outbound, and polls inbox/requests/responses, emitting events ----
  startPump(handle: number, intervalMs: number): Promise<void>;
  stopPump(handle: number): Promise<void>;

  // ---- bearer seam (drive a transport from JS) ----
  linkUp(handle: number, link: number, role: string): Promise<void>;
  linkDown(handle: number, link: number): Promise<void>;
  bytesReceived(handle: number, link: number, bytesB64: string): Promise<void>;

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
