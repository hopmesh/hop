// HopDemo, React Native. This port uses the same platform driver as the native demos, so discovery,
// transports, peer history, and messages all come from the real mesh instead of a JavaScript bearer.
// Real safe areas and the keyboard-aware composer are part of the screen contract on both platforms.

import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  FlatList,
  Keyboard,
  KeyboardAvoidingView,
  Linking,
  Platform,
  ScrollView,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import {SafeAreaProvider, SafeAreaView} from 'react-native-safe-area-context';
import Icon from 'react-native-vector-icons/FontAwesome6';
import {
  HopDriver,
  type DriverMessage,
  type DriverPeer,
  type DriverSubscription,
  type DriverTransports,
} from '@hop-mesh/react-native';
import {shortAddress} from './src/demoFormat';
import {generateParticipantName} from './src/names';
import {hop, type as typo} from './src/theme';

type AppPhase = 'checking-permissions' | 'permission-denied' | 'starting' | 'running' | 'failed';
type MessageThreads = Record<string, DriverMessage[]>;

type AutomationURL = {
  command: string;
  params: Record<string, string>;
};

function parseAutomationURL(value: string): AutomationURL | null {
  const match = /^hopdemo:\/\/([^/?#]+)(?:\/[^?#]*)?(?:\?([^#]*))?(?:#.*)?$/i.exec(
    value.trim(),
  );
  if (match == null) {
    return null;
  }

  const params: Record<string, string> = {};
  for (const field of (match[2] ?? '').split('&')) {
    if (field.length === 0) {
      continue;
    }
    const separator = field.indexOf('=');
    const rawKey = separator < 0 ? field : field.slice(0, separator);
    const rawValue = separator < 0 ? '' : field.slice(separator + 1);
    try {
      const key = decodeURIComponent(rawKey.replace(/\+/g, ' '));
      params[key] = decodeURIComponent(rawValue.replace(/\+/g, ' '));
    } catch {
      return null;
    }
  }
  return {command: match[1].toLowerCase(), params};
}

function latestMineStatus(messages: DriverMessage[]): string | null {
  let latest: DriverMessage | null = null;
  for (const message of messages) {
    if (message.mine && (latest == null || message.at >= latest.at)) {
      latest = message;
    }
  }
  return latest?.status ?? null;
}

// Display order for Status toggles. Native dictionaries do not keep insertion order, so
// Object.entries would shuffle the rows on every poll and the switch you aimed at would move.
const TRANSPORT_ORDER = ['Bluetooth', 'Peer-to-Peer', 'Local Net', 'Relay', 'LoRa'];

function orderedTransportEntries(
  transports: DriverTransports,
): Array<[string, DriverTransports[string]]> {
  return Object.keys(transports)
    .sort((a, b) => {
      const ia = TRANSPORT_ORDER.indexOf(a);
      const ib = TRANSPORT_ORDER.indexOf(b);
      const ra = ia === -1 ? TRANSPORT_ORDER.length : ia;
      const rb = ib === -1 ? TRANSPORT_ORDER.length : ib;
      if (ra !== rb) {
        return ra - rb;
      }
      return a.localeCompare(b);
    })
    .map(name => [name, transports[name]]);
}

function transportsJson(transports: DriverTransports): string {
  const ordered: DriverTransports = {};
  for (const [name, state] of orderedTransportEntries(transports)) {
    ordered[name] = state;
  }
  return JSON.stringify(ordered);
}

export default function App(): React.JSX.Element {
  const [phase, setPhase] = useState<AppPhase>('checking-permissions');
  const [missingPermissions, setMissingPermissions] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [participantName, setParticipantName] = useState<string | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [peers, setPeers] = useState<DriverPeer[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [addressTarget, setAddressTarget] = useState<DriverPeer | null>(null);
  const [threads, setThreads] = useState<MessageThreads>({});
  const [draft, setDraft] = useState('');
  const [sendState, setSendState] = useState<string | null>(null);
  const [sentAt, setSentAt] = useState<number | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [transports, setTransports] = useState<DriverTransports>({});
  const [transportError, setTransportError] = useState<string | null>(null);
  const [togglingTransport, setTogglingTransport] = useState<string | null>(null);
  const [peerDraft, setPeerDraft] = useState('');
  const [peerNote, setPeerNote] = useState<string | null>(null);
  const [tab, setTab] = useState(0);

  const scrollRef = useRef<React.ComponentRef<typeof ScrollView> | null>(null);
  const mountedRef = useRef(false);
  const bootAttemptRef = useRef(0);
  const startedRef = useRef(false);
  const selectedRef = useRef<string | null>(null);
  const loggedIncomingRef = useRef(new Set<string>());
  const pendingAutomationRef = useRef<string[]>([]);
  const lastTransportsJsonRef = useRef('');

  // React Native 0.87 is edge-to-edge on Android, so adjustResize alone does not lift the composer.
  // Paying the measured keyboard height as scroll padding gives the focused input and Send button room
  // to move above the keyboard. iOS also keeps automaticallyAdjustKeyboardInsets below.
  const [keyboardInset, setKeyboardInset] = useState(0);
  useEffect(() => {
    const show = Keyboard.addListener(
      Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow',
      event => setKeyboardInset(event.endCoordinates.height),
    );
    const hide = Keyboard.addListener(
      Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide',
      () => setKeyboardInset(0),
    );
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);

  const revealComposer = useCallback(() => {
    setTimeout(() => scrollRef.current?.scrollToEnd({animated: true}), 180);
  }, []);

  useEffect(() => {
    if (sentAt == null) {
      return;
    }
    setElapsed(0);
    const timer = setInterval(
      () => setElapsed(Math.floor((Date.now() - sentAt) / 1000)),
      1000,
    );
    return () => clearInterval(timer);
  }, [sentAt]);

  const applyMessages = useCallback(
    (peerAddress: string, messages: DriverMessage[], logIncoming: boolean) => {
      if (logIncoming) {
        for (const message of messages) {
          const receiptKey = `${peerAddress}:${message.id}`;
          if (!message.mine && !loggedIncomingRef.current.has(receiptKey)) {
            loggedIncomingRef.current.add(receiptKey);
            console.log('HOPRECV', JSON.stringify({from: peerAddress, body: message.body}));
          }
        }
      }

      setThreads(previous => ({...previous, [peerAddress]: messages}));
      if (selectedRef.current === peerAddress) {
        const status = latestMineStatus(messages);
        if (status != null) {
          setSendState(status);
          setSentAt(status === 'sending' ? previous => previous ?? Date.now() : null);
        }
      }
    },
    [],
  );

  const runAutomationURL = useCallback(async (url: string) => {
    console.log('HOPURL', url);
    const parsed = parseAutomationURL(url);
    if (
      parsed == null ||
      (parsed.command !== 'send' && parsed.command !== 'bearer' && parsed.command !== 'relay')
    ) {
      return;
    }
    if (!startedRef.current) {
      pendingAutomationRef.current.push(url);
      return;
    }

    if (parsed.command === 'send') {
      const to = parsed.params.to?.trim() ?? '';
      const body = parsed.params.text;
      let result: {ok: boolean; detail?: string};
      if (to.length === 0 || body == null) {
        result = {ok: false, detail: 'send automation requires to and text'};
      } else {
        try {
          result = await HopDriver.send(body, to);
        } catch (cause) {
          result = {ok: false, detail: String(cause)};
        }
      }
      console.log('HOPSEND', JSON.stringify({to, body: body ?? '', result}));
      return;
    }

    if (parsed.command === 'relay') {
      const relayUrl = parsed.params.url?.trim() ?? '';
      try {
        await HopDriver.setPinnedRelay(relayUrl.length === 0 ? null : relayUrl);
        console.log('HOPRELAY', JSON.stringify({url: relayUrl, result: {ok: true}}));
      } catch (cause) {
        console.log(
          'HOPRELAY',
          JSON.stringify({url: relayUrl, result: {ok: false, detail: String(cause)}}),
        );
      }
      return;
    }

    const transport = parsed.params.name?.trim() ?? '';
    const enabledValue = parsed.params.enabled;
    if (transport.length === 0 || (enabledValue !== 'true' && enabledValue !== 'false')) {
      setTransportError('bearer automation requires name and enabled=true|false');
      return;
    }
    try {
      await HopDriver.setTransportEnabled(transport, enabledValue === 'true');
      const nextTransports = await HopDriver.transports();
      lastTransportsJsonRef.current = transportsJson(nextTransports);
      console.log('HOPXPORT', lastTransportsJsonRef.current);
      setTransports(nextTransports);
    } catch (cause) {
      setTransportError(String(cause));
      console.log('HOPXPORT', JSON.stringify({error: String(cause), transport, enabled: enabledValue}));
    }
  }, []);

  const initialize = useCallback(async () => {
    const attempt = bootAttemptRef.current + 1;
    bootAttemptRef.current = attempt;
    setError(null);
    setPhase('checking-permissions');

    try {
      const permission = await HopDriver.ensurePermissions();
      if (!mountedRef.current || attempt !== bootAttemptRef.current) {
        return;
      }
      if (!permission.granted) {
        setMissingPermissions(permission.missing);
        setPhase('permission-denied');
        return;
      }

      setMissingPermissions([]);
      setPhase('starting');
      const storedName = await HopDriver.persistedName();
      if (!mountedRef.current || attempt !== bootAttemptRef.current) {
        return;
      }

      let name = storedName?.trim() ?? '';
      if (name.length === 0) {
        name = generateParticipantName();
        await HopDriver.savePersistedName(name);
      }
      if (!mountedRef.current || attempt !== bootAttemptRef.current) {
        return;
      }

      setParticipantName(name);
      await HopDriver.start(name);
      startedRef.current = true;
      if (!mountedRef.current || attempt !== bootAttemptRef.current) {
        startedRef.current = false;
        await HopDriver.stop();
        return;
      }

      const [ownAddress, initialPeers, initialTransports] = await Promise.all([
        HopDriver.selfAddress(),
        HopDriver.peers(),
        HopDriver.transports(),
      ]);
      if (!mountedRef.current || attempt !== bootAttemptRef.current) {
        return;
      }

      console.log('HOPSELF', JSON.stringify({address: ownAddress, name}));
      console.log('HOPPULL', JSON.stringify({peers: initialPeers.length}));
      setAddress(ownAddress);
      setPeers(initialPeers);
      setTransports(initialTransports);
      setPhase('running');

      const queuedURLs = pendingAutomationRef.current.splice(0);
      for (const queuedURL of queuedURLs) {
        await runAutomationURL(queuedURL);
      }
    } catch (cause) {
      if (mountedRef.current && attempt === bootAttemptRef.current) {
        setError(String(cause));
        setPhase('failed');
      }
    }
  }, [runAutomationURL]);

  useEffect(() => {
    mountedRef.current = true;
    let subscriptions: DriverSubscription[] = [];
    try {
      subscriptions = [
        HopDriver.onPeers(nextPeers => {
          // Counts only, and it earns its place: the native bridge was measured emitting three peers on
          // device while this list rendered "looking for others", so the question of WHERE the rows are
          // lost has to be answerable from the app side too, not just the bridge side.
          console.log(
            'HOPPEERS',
            JSON.stringify({n: nextPeers.length, up: nextPeers.filter(p => p.active).length}),
          );
          setPeers(nextPeers);
        }),
        HopDriver.onMessages(event => applyMessages(event.peer, event.messages, true)),
        HopDriver.onTransports(nextTransports => {
          console.log('HOPXPORT', transportsJson(nextTransports));
          setTransports(nextTransports);
        }),
      ];
      void initialize();
    } catch (cause) {
      setError(String(cause));
      setPhase('failed');
    }

    return () => {
      mountedRef.current = false;
      bootAttemptRef.current += 1;
      for (const subscription of subscriptions) {
        subscription.remove();
      }
      if (startedRef.current) {
        startedRef.current = false;
        void HopDriver.stop();
      }
    };
  }, [applyMessages, initialize]);

  // Automation URLs arrive through the NATIVE bridge, not React Native's Linking.
  //
  // Measured on release builds of React Native 0.87 bridgeless, on both platforms: an app started by
  // `am start -a VIEW -d hopdemo://send?...` boots and reports its address, while Linking.getInitialURL()
  // resolves empty and the warm 'url' listener never fires. On iOS the native side even confirms the
  // AppDelegate forwarded the URL into RCTLinkingManager and it was accepted, and JavaScript still never
  // saw it. Linking stays subscribed below because it costs nothing and would be the right path if a
  // future version delivers, but the bridge is what this app depends on.
  useEffect(() => {
    const linkingSubscription = Linking.addEventListener('url', event => {
      void runAutomationURL(event.url);
    });
    const bridgeSubscription = HopDriver.onUrl(url => {
      void runAutomationURL(url);
    });
    void HopDriver.launchURL()
      .then(url => {
        if (url != null) {
          void runAutomationURL(url);
        }
      })
      .catch(cause => {
        console.log('HOPURL', JSON.stringify({error: String(cause)}));
      });
    return () => {
      linkingSubscription.remove();
      bridgeSubscription.remove();
    };
  }, [runAutomationURL]);

  // Mesh state is POLLED, not awaited from events.
  //
  // Measured on a release build, React Native 0.87 bridgeless on Android, in one process: JavaScript
  // registered its subscriptions (HOPSUB for all four events) at 02:29:22.540, the native module emitted
  // HopDriver:peers with three rows at 02:29:23.417 with an active React instance and no drop, and the
  // listener never fired. Three publish paths were tried from the native side, getJSModule with
  // RCTDeviceEventEmitter, ReactContext.emitDeviceEvent, and a DeviceEventEmitter subscription in place
  // of NativeEventEmitter, and none delivered. Promise-returning calls work, so the bridged reads are the
  // channel this app can actually rely on. A one-second poll is cheap next to a mesh that changes on the
  // order of seconds, and it also fixes the startup race the single pull had: peers() answered zero
  // before discovery converged and nothing ever replaced that answer.
  useEffect(() => {
    if (phase !== 'running') {
      return;
    }
    let cancelled = false;
    let ticks = 0;
    const tick = async () => {
      try {
        const [nextPeers, nextTransports] = await Promise.all([
          HopDriver.peers(),
          HopDriver.transports(),
        ]);
        if (cancelled || !mountedRef.current) {
          return;
        }
        setPeers(nextPeers);
        setTransports(nextTransports);
        const transportsJsonText = transportsJson(nextTransports);
        if (transportsJsonText !== lastTransportsJsonRef.current) {
          lastTransportsJsonRef.current = transportsJsonText;
          console.log('HOPXPORT', transportsJsonText);
        }
        if (ticks++ % 10 === 0) {
          console.log(
            'HOPPOLL',
            JSON.stringify({
              peers: nextPeers.length,
              up: nextPeers.filter(peer => peer.active).length,
              transports: Object.keys(nextTransports).length,
            }),
          );
        }
        const open = selectedRef.current;
        const peersToScan = nextPeers.map(peer => peer.address);
        if (open != null && !peersToScan.includes(open)) {
          peersToScan.push(open);
        }
        for (const peerAddress of peersToScan) {
          const messages = await HopDriver.messages(peerAddress);
          if (cancelled || !mountedRef.current) {
            return;
          }
          applyMessages(peerAddress, messages, true);
        }
      } catch (cause) {
        console.log('HOPPOLL', JSON.stringify({error: String(cause)}));
      }
    };
    void tick();
    const timer = setInterval(() => void tick(), 1000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [phase, applyMessages]);

  const openPeer = useCallback(
    (peerAddress: string) => {
      selectedRef.current = peerAddress;
      setSelected(peerAddress);
      setSendState(null);
      setSentAt(null);
      void HopDriver.messages(peerAddress)
        .then(messages => {
          if (mountedRef.current && selectedRef.current === peerAddress) {
            applyMessages(peerAddress, messages, false);
          }
        })
        .catch(cause => {
          if (mountedRef.current && selectedRef.current === peerAddress) {
            setSendState(`messages failed: ${String(cause)}`);
          }
        });
    },
    [applyMessages],
  );

  const closePeer = useCallback(() => {
    selectedRef.current = null;
    setSelected(null);
    setSendState(null);
    setSentAt(null);
  }, []);

  const findPeer = useCallback(() => {
    const typed = peerDraft.trim();
    if (typed.length === 0) {
      setPeerNote('paste an address first');
      return;
    }
    if (typed === address) {
      setPeerNote('that is this device, not a peer');
      return;
    }
    if (!/^[1-9A-HJ-NP-Za-km-z]{16,}$/.test(typed)) {
      setPeerNote('not a base58 Hop address');
      return;
    }

    const discovered = peers.find(peer => peer.address === typed) ?? null;
    const target =
      discovered ??
      ({
        address: typed,
        name: shortAddress(typed),
        hops: 0,
        platform: '',
        app: '',
        active: false,
      } satisfies DriverPeer);
    setAddressTarget(discovered == null ? target : null);
    setPeerDraft('');
    setPeerNote(null);
    openPeer(target.address);
  }, [address, openPeer, peerDraft, peers]);

  const send = useCallback(async () => {
    const target = selectedRef.current;
    const body = draft.trim();
    if (target == null || body.length === 0) {
      return;
    }

    setSendState('sending');
    setSentAt(Date.now());
    try {
      const result = await HopDriver.send(body, target);
      if (!result.ok) {
        setSendState(`failed${result.detail ? `: ${result.detail}` : ''}`);
        setSentAt(null);
        return;
      }

      setDraft('');
      const messages = await HopDriver.messages(target);
      if (!mountedRef.current || selectedRef.current !== target) {
        return;
      }
      applyMessages(target, messages, false);
      const status = latestMineStatus(messages) ?? result.detail ?? 'sent';
      setSendState(status);
      setSentAt(status === 'sending' ? previous => previous ?? Date.now() : null);
    } catch (cause) {
      if (mountedRef.current && selectedRef.current === target) {
        setSendState(`failed: ${String(cause)}`);
        setSentAt(null);
      }
    }
  }, [applyMessages, draft]);

  const toggleTransport = useCallback(async (transport: string, enabled: boolean) => {
    setTransportError(null);
    setTogglingTransport(transport);
    try {
      await HopDriver.setTransportEnabled(transport, enabled);
    } catch (cause) {
      if (mountedRef.current) {
        setTransportError(String(cause));
      }
    } finally {
      if (mountedRef.current) {
        setTogglingTransport(null);
      }
    }
  }, []);

  if (phase === 'checking-permissions' || phase === 'starting') {
    return (
      <SafeAreaProvider>
        <SafeAreaView style={styles.center} edges={['top', 'bottom']} testID="screen-loading">
          <ActivityIndicator />
          <Text style={styles.dim}>
            {phase === 'checking-permissions' ? 'checking permissions' : 'starting driver'}
          </Text>
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

  if (phase === 'permission-denied') {
    return (
      <SafeAreaProvider>
        <SafeAreaView
          style={styles.permissionGate}
          edges={['top', 'bottom', 'left', 'right']}
          testID="screen-permission">
          <Text style={styles.permissionTitle}>Nearby-device access needed</Text>
          <Text style={styles.permissionBody} testID="permission-explanation">
            Hop forms its mesh over Bluetooth LE to nearby phones. Without the nearby-devices
            (Bluetooth) permission it can't scan, advertise, or relay, so nothing will send or arrive.
          </Text>
          {missingPermissions.length > 0 ? (
            <Text style={styles.tiny} testID="missing-permissions">
              Missing: {missingPermissions.join(', ')}
            </Text>
          ) : null}
          <TouchableOpacity
            style={styles.btnSmall}
            testID="grant-permission-button"
            onPress={() => void initialize()}>
            <Text style={styles.btnSmallText}>Grant permission</Text>
          </TouchableOpacity>
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

  if (phase === 'failed') {
    return (
      <SafeAreaProvider>
        <SafeAreaView style={styles.center} edges={['top', 'bottom']} testID="screen-error">
          <Text style={styles.err} testID="error-text">
            {error}
          </Text>
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

  const selectedPeer =
    peers.find(peer => peer.address === selected) ??
    (addressTarget?.address === selected ? addressTarget : null);
  const thread = selected == null ? [] : threads[selected] ?? [];

  const Tab = ({id, icon, label}: {id: number; icon: string; label: string}) => (
    <TouchableOpacity
      testID={`tab-${label.toLowerCase()}`}
      style={styles.tabItem}
      onPress={() => setTab(id)}>
      <Icon name={icon} size={20} color={tab === id ? hop.accent : hop.secondary} />
      <Text style={[styles.tabLabel, {color: tab === id ? hop.accent : hop.secondary}]}>
        {label}
      </Text>
    </TouchableOpacity>
  );

  return (
    <SafeAreaProvider>
      <SafeAreaView
        style={styles.root}
        edges={['top']}
        testID="screen-main">
        <StatusBar barStyle="dark-content" />
        <SafeAreaView style={styles.fill} edges={['left', 'right']}>
        <KeyboardAvoidingView
          style={styles.fill}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          {tab === 0 && selectedPeer != null ? (
            <ChatThread
              peer={selectedPeer}
              thread={thread}
              sendState={sendState}
              elapsed={elapsed}
              onBack={closePeer}
              draft={draft}
              setDraft={setDraft}
              send={send}
              keyboardInset={Platform.OS === 'android' ? keyboardInset : 0}
            />
          ) : (
            <ScrollView
              ref={scrollRef}
              testID="main-scroll"
              contentContainerStyle={[styles.screenBody, {paddingBottom: 24 + keyboardInset}]}
              keyboardShouldPersistTaps="handled"
              keyboardDismissMode="on-drag"
              automaticallyAdjustKeyboardInsets>
              {tab === 0 ? (
                <ChatsTab
                  peers={peers}
                  peerDraft={peerDraft}
                  setPeerDraft={setPeerDraft}
                  peerNote={peerNote}
                  findPeer={findPeer}
                  onPick={openPeer}
                  revealComposer={revealComposer}
                />
              ) : null}
              {tab === 1 ? <RelaysTab transports={transports} /> : null}
              {tab === 2 ? <WebTab /> : null}
              {tab === 3 ? (
                <StatusTab
                  address={address}
                  participantName={participantName}
                  transports={transports}
                  transportError={transportError}
                  togglingTransport={togglingTransport}
                  onToggleTransport={toggleTransport}
                />
              ) : null}
            </ScrollView>
          )}
        </KeyboardAvoidingView>
        </SafeAreaView>
        <SafeAreaView style={styles.tabBarSafeArea} edges={['bottom', 'left', 'right']}>
          <View style={styles.tabBar}>
            <Tab id={0} icon="comment" label="Chats" />
            <Tab id={1} icon="tower-broadcast" label="Relays" />
            <Tab id={2} icon="globe" label="Web" />
            <Tab id={3} icon="gear" label="Status" />
          </View>
        </SafeAreaView>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

function ChatsTab({
  peers,
  peerDraft,
  setPeerDraft,
  peerNote,
  findPeer,
  onPick,
  revealComposer,
}: {
  peers: DriverPeer[];
  peerDraft: string;
  setPeerDraft: (value: string) => void;
  peerNote: string | null;
  findPeer: () => void;
  onPick: (address: string) => void;
  revealComposer: () => void;
}) {
  const direct = peers.filter(peer => peer.active && peer.hops <= 1);
  const relayed = peers.filter(peer => peer.active && peer.hops > 1);
  const offline = peers.filter(peer => !peer.active);

  return (
    <View>
      <Text style={styles.headline}>Chats</Text>
      <Text style={styles.dim} testID="bearer-note">
        Discovery and message transport come from the platform Hop driver, using the same radio and
        relay bearers as the native demos.
      </Text>

      <Text style={styles.h2}>Open by address</Text>
      <View style={styles.rowWrap}>
        <TextInput
          style={styles.inputFlex}
          testID="peer-address-input"
          value={peerDraft}
          onChangeText={setPeerDraft}
          onFocus={revealComposer}
          placeholder="base58 address"
          autoCorrect={false}
          autoCapitalize="none"
        />
        <TouchableOpacity style={styles.btnSmall} testID="add-peer-button" onPress={findPeer}>
          <Icon name="arrow-right" size={14} color={hop.accentInk} />
          <Text style={styles.btnSmallText}>Open</Text>
        </TouchableOpacity>
      </View>
      {peerNote ? (
        <Text style={styles.err} testID="add-peer-status">
          {peerNote}
        </Text>
      ) : null}
      <Text style={styles.tiny} testID="add-peer-note">
        A full address can open a direct chat while driver discovery is still converging.
      </Text>

      <View testID="peers-list">
        {peers.length === 0 ? (
          <Text style={styles.dim} testID="peers-empty">
            looking for others…
          </Text>
        ) : null}

        <Text style={styles.h2}>Nearby (direct)</Text>
        {direct.length === 0 ? <Text style={styles.dim}>none</Text> : null}
        {direct.map((peer, index) => (
          <PeerRow key={peer.address} peer={peer} index={index} onPick={onPick} />
        ))}

        <Text style={styles.h2}>In the mesh (relayed)</Text>
        {relayed.length === 0 ? <Text style={styles.dim}>none</Text> : null}
        {relayed.map((peer, index) => (
          <PeerRow
            key={peer.address}
            peer={peer}
            index={direct.length + index}
            onPick={onPick}
          />
        ))}

        {offline.length > 0 ? (
          <>
            <Text style={styles.h2}>Conversations and seen (offline)</Text>
            {offline.map((peer, index) => (
              <PeerRow
                key={peer.address}
                peer={peer}
                index={direct.length + relayed.length + index}
                onPick={onPick}
              />
            ))}
          </>
        ) : null}
      </View>
    </View>
  );
}

function PeerRow({
  peer,
  index,
  onPick,
}: {
  peer: DriverPeer;
  index: number;
  onPick: (address: string) => void;
}) {
  const route = !peer.active ? 'offline' : peer.hops <= 1 ? 'direct' : `${peer.hops} hops`;
  const platform = peer.platform.trim().toLowerCase();
  const platformName =
    platform === 'apple' || platform === 'ios'
      ? 'Apple'
      : platform === 'android'
        ? 'Android'
        : platform === 'cloud'
          ? 'Cloud'
          : peer.platform;
  const details = [platformName, peer.app].filter(value => value.length > 0).join(' · ');

  return (
    <TouchableOpacity
      testID={`peer-row-${index}`}
      style={styles.peerRow}
      onPress={() => onPick(peer.address)}>
      <View style={styles.peerIcon}>
        <View
          style={[
            styles.dot,
            {backgroundColor: peer.active ? hop.active : hop.secondary},
          ]}
        />
      </View>
      <View style={styles.inputFlex}>
        <Text style={styles.peerTitle}>{peer.name}</Text>
        <Text style={styles.dim} testID={`peer-address-${index}`}>
          {shortAddress(peer.address)}
        </Text>
        {details.length > 0 ? <Text style={styles.tiny}>{details}</Text> : null}
      </View>
      <Text style={styles.tiny} testID={`peer-transport-${index}`}>
        {route}
      </Text>
      <Icon name="chevron-right" size={14} color={hop.tertiary} />
    </TouchableOpacity>
  );
}

function ChatThread({
  peer,
  thread,
  sendState,
  elapsed,
  onBack,
  draft,
  setDraft,
  send,
  keyboardInset,
}: {
  peer: DriverPeer;
  thread: DriverMessage[];
  sendState: string | null;
  elapsed: number;
  onBack: () => void;
  draft: string;
  setDraft: (value: string) => void;
  send: () => void;
  keyboardInset: number;
}) {
  const newestFirst = useMemo(
    () =>
      [...thread].sort(
        (left, right) => right.at - left.at || right.id.localeCompare(left.id),
      ),
    [thread],
  );

  return (
    <View style={[styles.chatScreen, {paddingBottom: keyboardInset}]} testID="chat-screen">
      <View style={styles.chatHeader}>
        <TouchableOpacity testID="chat-back" onPress={onBack} style={styles.backBtn}>
          <Icon name="chevron-left" size={16} color={hop.accent} />
          <Text style={styles.backText}>Chats</Text>
        </TouchableOpacity>
        <Text style={styles.chatTitle} testID="chat-title" numberOfLines={1}>
          {peer.name}
        </Text>
      </View>

      {newestFirst.length === 0 ? (
        <View style={styles.messagesEmpty}>
          <Text style={styles.dim} testID="messages-empty">
            no messages yet
          </Text>
        </View>
      ) : (
        <FlatList
          inverted
          style={styles.messagesList}
          contentContainerStyle={styles.messagesContent}
          testID="messages-list"
          data={newestFirst}
          keyExtractor={message => message.id}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
          maintainVisibleContentPosition={{minIndexForVisible: 0}}
          renderItem={({item, index}) => (
            <View
              style={[styles.bubbleWrap, {alignItems: item.mine ? 'flex-end' : 'flex-start'}]}
              testID={`message-row-${index}`}>
              <View style={[styles.bubble, item.mine ? styles.bubbleMine : styles.bubbleIn]}>
                <Text style={styles.bubbleText} testID={`message-body-${index}`}>
                  {item.body}
                </Text>
              </View>
              <Text style={styles.meta} testID={`message-from-${index}`}>
                {item.mine
                  ? `${item.status} · ${new Date(item.at).toLocaleTimeString()}`
                  : `${shortAddress(peer.address)} · ${item.status} · ${new Date(
                      item.at,
                    ).toLocaleTimeString()}`}
              </Text>
            </View>
          )}
        />
      )}

      <View style={styles.composerArea}>
        {sendState === 'sending' ? <SendingIndicator elapsed={elapsed} /> : null}
        {sendState ? (
          <Text style={styles.dim} testID="send-status">
            {sendState}
          </Text>
        ) : null}
        <View style={styles.composerRow}>
          <TextInput
            style={styles.inputFlex}
            testID="message-input"
            value={draft}
            onChangeText={setDraft}
            placeholder={`Message ${peer.name}`}
            autoCorrect={false}
          />
          <TouchableOpacity
            style={[styles.btnSend, draft.trim().length === 0 && styles.btnDisabled]}
            testID="send-button"
            onPress={send}
            disabled={draft.trim().length === 0}>
            <Icon
              name="paper-plane"
              size={14}
              color={draft.trim().length === 0 ? hop.secondary : hop.accentInk}
            />
            <Text
              style={[
                styles.btnSmallText,
                {color: draft.trim().length === 0 ? hop.secondary : hop.accentInk},
              ]}>
              Send
            </Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
}

function SendingIndicator({elapsed}: {elapsed: number}) {
  const pulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const animation = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, {
          toValue: 0.25,
          duration: 600,
          easing: Easing.inOut(Easing.quad),
          useNativeDriver: true,
        }),
        Animated.timing(pulse, {
          toValue: 1,
          duration: 600,
          easing: Easing.inOut(Easing.quad),
          useNativeDriver: true,
        }),
      ]),
    );
    animation.start();
    return () => animation.stop();
  }, [pulse]);

  return (
    <View style={styles.pulseRow} testID="sending-indicator">
      <Animated.View style={[styles.pulseDot, {opacity: pulse}]} />
      <Text style={styles.meta}>Awaiting peers · {elapsed}s</Text>
    </View>
  );
}

function RelaysTab({transports}: {transports: DriverTransports}) {
  const relayEntries = orderedTransportEntries(transports).filter(([name]) =>
    name.toLowerCase().includes('relay'),
  );
  const relay = relayEntries[0] ?? null;
  const relayState = relay?.[1] ?? 'starting';
  const color =
    relayState === 'active' ? hop.active : relayState === 'off' ? hop.danger : hop.pulse;

  return (
    <View>
      <Text style={styles.headline}>Relays</Text>
      <View style={styles.relayRow}>
        <View style={[styles.dot, {backgroundColor: color}]} />
        <View style={styles.inputFlex}>
          <Text style={styles.body}>{relay?.[0] ?? 'Relay'}</Text>
          <Text style={styles.dim} testID="relay-status">
            {relayState}
          </Text>
        </View>
      </View>
      <Text style={styles.monoSmall} testID="relay-url">
        Platform driver configuration
      </Text>
      <Text style={styles.dim} testID="relay-url-input">
        Relay endpoints are selected by the native driver.
      </Text>
      <Text style={styles.tiny} testID="relay-connect-button">
        Connection is automatic when Relay is enabled.
      </Text>
      <Text style={styles.tiny} testID="relay-note">
        Active means the bearer has a live link. Idle means it is enabled and waiting for one. Off
        means it was disabled in platform configuration.
      </Text>
    </View>
  );
}

function WebTab() {
  return (
    <View>
      <Text style={styles.headline}>Web</Text>
      <Text style={styles.dim} testID="web-unavailable">
        hops:// browsing needs the Hop driver's proxy, which this bridge does not expose yet. The
        native demos carry this tab; this port says so instead of showing a browser that cannot fetch.
      </Text>
    </View>
  );
}

function StatusTab({
  address,
  participantName,
  transports,
  transportError,
  togglingTransport,
  onToggleTransport,
}: {
  address: string | null;
  participantName: string | null;
  transports: DriverTransports;
  transportError: string | null;
  togglingTransport: string | null;
  onToggleTransport: (transport: string, enabled: boolean) => void;
}) {
  const entries = orderedTransportEntries(transports);

  return (
    <View>
      <Text style={styles.headline}>Status</Text>
      <Text style={styles.h2}>Participant</Text>
      <Text style={styles.peerTitle} testID="participant-name">
        {participantName}
      </Text>
      <Text style={styles.h2}>This device</Text>
      <Text style={styles.mono} testID="own-address" selectable>
        {address}
      </Text>
      <Text style={styles.dim} testID="own-address-short">
        {address ? shortAddress(address) : ''}
      </Text>

      <Text style={styles.h2}>Transports</Text>
      {entries.length === 0 ? <Text style={styles.dim}>starting…</Text> : null}
      {entries.map(([name, state]) => (
        <View style={styles.transportRow} key={name}>
          <Switch
            testID={`transport-toggle-${name}`}
            value={state !== 'off'}
            disabled={togglingTransport != null}
            onValueChange={enabled => onToggleTransport(name, enabled)}
          />
          <View style={styles.transportText}>
            <Text style={styles.body} testID={`transport-name-${name}`}>
              {name}
            </Text>
            <Text style={styles.dim} testID={`transport-status-${name}`}>
              {state === 'off' ? 'disabled' : state === 'idle' ? 'no links' : 'active'}
            </Text>
          </View>
          {togglingTransport === name ? <ActivityIndicator size="small" /> : null}
        </View>
      ))}
      {transportError ? (
        <Text style={styles.err} testID="transport-error">
          {transportError}
        </Text>
      ) : null}

      <Text style={styles.h2}>My QR</Text>
      <Text style={styles.dim} testID="qr-unavailable">
        QR rendering is a platform graphics API with no bundled React Native equivalent, so it is
        unavailable here rather than shown as a blank box. The native demos draw it.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: hop.bg},
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: hop.bg,
    padding: 24,
  },
  fill: {flex: 1},
  screenBody: {padding: 16, gap: 6},
  headline: typo.headline,
  h2: {fontSize: 16, fontWeight: '600', marginTop: 18, marginBottom: 4},
  body: typo.body,
  dim: {color: hop.secondary},
  tiny: {fontSize: 11, color: hop.tertiary},
  meta: {fontSize: 12, color: hop.secondary},
  err: {color: hop.danger},
  mono: typo.mono,
  monoSmall: {fontSize: 12, fontFamily: 'Menlo', color: hop.secondary},

  permissionGate: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: hop.bg,
    padding: 24,
    gap: 16,
  },
  permissionTitle: {fontSize: 24, fontWeight: '600', color: hop.fg},
  permissionBody: {...typo.body, textAlign: 'center'},

  tabBarSafeArea: {backgroundColor: hop.barBg},
  tabBar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: hop.hairline,
    backgroundColor: hop.barBg,
  },
  tabItem: {flex: 1, alignItems: 'center', paddingVertical: 8, gap: 2},
  tabLabel: {fontSize: 10},

  chatScreen: {flex: 1, backgroundColor: hop.bg},
  messagesList: {flex: 1},
  messagesContent: {paddingHorizontal: 16, paddingVertical: 8},
  messagesEmpty: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  composerArea: {
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: hop.hairline,
    backgroundColor: hop.bg,
  },
  composerRow: {flexDirection: 'row', alignItems: 'center', gap: 8},
  chatHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: hop.hairline,
  },
  backBtn: {flexDirection: 'row', alignItems: 'center', gap: 2},
  backText: {color: hop.accent, fontSize: 16},
  chatTitle: {...typo.title, flex: 1},

  peerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: hop.hairline,
  },
  peerIcon: {width: 20, alignItems: 'center'},
  peerTitle: {fontWeight: '600'},
  dot: {width: 8, height: 8, borderRadius: 4},

  bubbleWrap: {alignSelf: 'stretch', gap: 2, marginVertical: 4},
  bubble: {borderRadius: 12, paddingHorizontal: 10, paddingVertical: 8, maxWidth: '80%'},
  bubbleMine: {backgroundColor: hop.accentDim},
  bubbleIn: {backgroundColor: hop.bubbleIncoming},
  bubbleText: {fontSize: 16},

  pulseRow: {flexDirection: 'row', alignItems: 'center', gap: 6, marginVertical: 4},
  pulseDot: {width: 8, height: 8, borderRadius: 4, backgroundColor: hop.pulse},
  relayRow: {flexDirection: 'row', alignItems: 'center', gap: 8, marginVertical: 8},
  transportRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: hop.hairline,
  },
  transportText: {flex: 1},

  rowWrap: {flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 6},
  inputFlex: {
    flex: 1,
    borderWidth: 1,
    borderColor: hop.hairline,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  btnSmall: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: hop.accent,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  btnSmallText: {color: hop.accentInk, fontWeight: '600'},
  btnSend: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: hop.accent,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  btnDisabled: {backgroundColor: hop.bubbleIncoming},
});
