// @hop-mesh/react-native: run a Hop mesh node inside a React Native app. This is the cross-platform
// client SDK; it wraps the native Hop client SDKs (sdk/apple on iOS, sdk/android on Android) through a
// single `HopMesh` native module and presents one TypeScript surface over both.
//
// Entry points: `Hop.ephemeral()` for a throwaway in-memory identity, `Hop.withSecret()` to restore
// one, and `Hop.open()` / `Hop.openKeyed()` for a persistent (optionally encrypted-at-rest) on-device
// store. Each resolves a `HopNode`; start its pump and subscribe to `onMessage` to receive.

import { fromBase64, toBase64 } from "./base64";
import { getHopEmitter, getHopNative } from "./native";
import { HopNode } from "./node";
import { HopOpenOptions } from "./types";

const EMPTY = "";

/** Factory for `HopNode`s, plus the base58 address helpers. */
export const Hop = {
  /** A fresh identity with ephemeral (in-memory) storage. */
  async ephemeral(): Promise<HopNode> {
    const native = getHopNative();
    return new HopNode(native, getHopEmitter(), await native.createEphemeral());
  },

  /** Restore from a saved 32-byte identity secret (empty = fresh) with ephemeral storage. */
  async withSecret(secret: Uint8Array): Promise<HopNode> {
    const native = getHopNative();
    return new HopNode(native, getHopEmitter(), await native.createWithSecret(toBase64(secret)));
  },

  /**
   * Open with persistent storage. Resolves null only when the db path is unusable.
   * Pass `key` (a raw 32-byte keystore key) to encrypt the store at rest (SQLCipher).
   */
  async open(opts: HopOpenOptions): Promise<HopNode | null> {
    const native = getHopNative();
    const secretB64 = opts.secret ? toBase64(opts.secret) : EMPTY;
    const appSecretB64 = opts.appSecret ? toBase64(opts.appSecret) : EMPTY;
    const handle = opts.key
      ? await native.openKeyed(opts.dbPath, toBase64(opts.key), secretB64, appSecretB64)
      : await native.openPersistent(opts.dbPath, secretB64, appSecretB64);
    return handle < 0 ? null : new HopNode(native, getHopEmitter(), handle);
  },
};

/** base58 address helpers, mirroring the native `HopAddress`. */
export const HopAddress = {
  /** Encode a 32-byte address as base58. */
  toBase58(bytes: Uint8Array): Promise<string> {
    return getHopNative().addressToBase58(toBase64(bytes));
  },
  /** Decode a base58 address string, or null if it is not exactly a 32-byte address. */
  async fromBase58(text: string): Promise<Uint8Array | null> {
    const b64 = await getHopNative().addressFromBase58(text);
    return b64 == null ? null : fromBase64(b64);
  },
};

export { HopNode } from "./node";
export type { Emitter, Subscription } from "./node";
export {
  toBase64,
  fromBase64,
  utf8ToBytes,
  bytesToUtf8,
  asBytes,
} from "./base64";
export type {
  HopMessage,
  HopStatus,
  HopServiceRequest,
  HopServiceResponse,
  HopOutgoing,
  HopRole,
  HopOpenOptions,
  HopSendOptions,
} from "./types";
export type { HopNativeModule } from "./native";
export { HopDriver, HopDriverEvent } from "./driver";
export type {
  DriverMessage,
  DriverMessagesEvent,
  DriverPeer,
  DriverPermissionResult,
  DriverSendResult,
  DriverSubscription,
  DriverTransports,
  HopDriverNativeModule,
} from "./driver";
