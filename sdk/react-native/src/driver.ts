// The platform driver bridge. Unlike the lower-level HopMesh module, HopDriver owns the real
// transports, discovery, peer history, and message threads used by the native demo apps.

export type DriverPeer = {
  address: string;
  name: string;
  hops: number;
  platform: string;
  app: string;
  active: boolean;
};

export type DriverMessage = {
  id: string;
  body: string;
  mine: boolean;
  at: number;
  status: string;
};

export type DriverPermissionResult = {
  granted: boolean;
  missing: string[];
};

export type DriverSendResult = {
  ok: boolean;
  detail?: string;
};

export type DriverMessagesEvent = {
  peer: string;
  messages: DriverMessage[];
};

export type DriverTransports = Record<string, string>;

export type DriverSubscription = {
  remove(): void;
};

export interface HopDriverNativeModule {
  ensurePermissions(): Promise<DriverPermissionResult>;
  start(name: string): Promise<void>;
  stop(): Promise<void>;
  setName(name: string): Promise<void>;
  persistedName(): Promise<string | null>;
  savePersistedName(name: string): Promise<void>;
  peers(): Promise<DriverPeer[]>;
  send(text: string, toAddressBase58: string): Promise<DriverSendResult>;
  messages(peerAddressBase58: string): Promise<DriverMessage[]>;
  selfAddress(): Promise<string>;
  transports(): Promise<DriverTransports>;
  setTransportEnabled(transport: string, enabled: boolean): Promise<void>;
  launchURL(): Promise<string | null>;
  addListener(eventType: string): void;
  removeListeners(count: number): void;
}

export const HopDriverEvent = {
  Peers: "HopDriver:peers",
  Messages: "HopDriver:messages",
  Transports: "HopDriver:transports",
  Url: "HopDriver:url",
} as const;

const LINK_ERROR =
  "@hop-mesh/react-native: the native HopDriver module is not linked. Rebuild the app after installing " +
  "the platform driver dependency (pod install for iOS, a Gradle sync for Android). This module has no " +
  "JavaScript transport fallback.";

let cachedModule: HopDriverNativeModule | null = null;
let cachedEmitter: {
  addListener(event: string, listener: (payload: unknown) => void): DriverSubscription;
} | null = null;

function nativeDriver(): HopDriverNativeModule {
  if (cachedModule) return cachedModule;
  const { NativeModules } = require("react-native");
  const module = NativeModules.HopDriver as HopDriverNativeModule | undefined;
  if (!module) throw new Error(LINK_ERROR);
  cachedModule = module;
  return module;
}

function driverEmitter(): {
  addListener(event: string, listener: (payload: unknown) => void): DriverSubscription;
} {
  if (cachedEmitter) return cachedEmitter;
  const { NativeEventEmitter } = require("react-native");
  const emitter = new NativeEventEmitter(nativeDriver()) as {
    addListener(event: string, listener: (payload: unknown) => void): DriverSubscription;
  };
  cachedEmitter = emitter;
  return emitter;
}

export const HopDriver = {
  ensurePermissions(): Promise<DriverPermissionResult> {
    return nativeDriver().ensurePermissions();
  },

  start(name: string): Promise<void> {
    return nativeDriver().start(name);
  },

  stop(): Promise<void> {
    return nativeDriver().stop();
  },

  setName(name: string): Promise<void> {
    return nativeDriver().setName(name);
  },

  persistedName(): Promise<string | null> {
    return nativeDriver().persistedName();
  },

  savePersistedName(name: string): Promise<void> {
    return nativeDriver().savePersistedName(name);
  },

  peers(): Promise<DriverPeer[]> {
    return nativeDriver().peers();
  },

  send(text: string, toAddressBase58: string): Promise<DriverSendResult> {
    return nativeDriver().send(text, toAddressBase58);
  },

  messages(peerAddressBase58: string): Promise<DriverMessage[]> {
    return nativeDriver().messages(peerAddressBase58);
  },

  selfAddress(): Promise<string> {
    return nativeDriver().selfAddress();
  },

  transports(): Promise<DriverTransports> {
    return nativeDriver().transports();
  },

  setTransportEnabled(transport: string, enabled: boolean): Promise<void> {
    return nativeDriver().setTransportEnabled(transport, enabled);
  },

  /**
   * The automation URL this app was launched or resumed with, consumed once.
   *
   * React Native's own Linking does not deliver on this stack. Measured on release builds of React Native
   * 0.87 bridgeless: an activity started by a VIEW intent boots the app and reports its address, while
   * getInitialURL() yields nothing and the warm 'url' listener never fires. iOS behaves the same way even
   * though the AppDelegate forward into RCTLinkingManager is accepted, so this is the framework path and
   * not one platform. The native module reads the intent itself, which is the only source that cannot lie.
   */
  launchURL(): Promise<string | null> {
    return nativeDriver().launchURL();
  },

  onUrl(listener: (url: string) => void): DriverSubscription {
    return driverEmitter().addListener(HopDriverEvent.Url, payload =>
      listener(payload as string),
    );
  },

  onPeers(listener: (peers: DriverPeer[]) => void): DriverSubscription {
    return driverEmitter().addListener(HopDriverEvent.Peers, payload =>
      listener(payload as DriverPeer[]),
    );
  },

  onMessages(listener: (event: DriverMessagesEvent) => void): DriverSubscription {
    return driverEmitter().addListener(HopDriverEvent.Messages, payload =>
      listener(payload as DriverMessagesEvent),
    );
  },

  onTransports(listener: (transports: DriverTransports) => void): DriverSubscription {
    return driverEmitter().addListener(HopDriverEvent.Transports, payload =>
      listener(payload as DriverTransports),
    );
  },
};
