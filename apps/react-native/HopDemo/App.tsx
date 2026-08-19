// HopDemo, React Native. A port of the two native HopDemo apps (apps/apple/HopDemo, SwiftUI, and
// apps/android/HopDemo, Compose) onto @hop-mesh/react-native, so one codebase exercises the bridge on
// both platforms.
//
// THE APP RUNS TWO PATHS AT ONCE, and the difference matters.
//
// 1. An in-process loopback pair (src/loopback.ts). Two nodes in this process, wired to each other.
//    This device is "you"; the second node stands in for a peer. Everything between them is real:
//    real Rust core, real sealing, real inbox. It proves the core and the bridge work on this device,
//    and it works with no network at all. What it cannot do, by construction, is reach another device.
//
// 2. A relay link from THIS device's node to a hop-relayd WebSocket front door (src/relayBearer.ts).
//    That is a real bearer, not a stand-in: relayd's WS door is an opaque byte pipe, one core packet
//    per binary frame, and the link's Noise handshake happens inside the node. This is what lets a
//    node on ANOTHER device reach this one, and it is how a two-device message actually travels.
//
// What is still missing, stated plainly rather than implied away: there is no radio bearer in the
// React Native SDK, no BLE and no LAN, so nothing here DISCOVERS a peer. A peer is reached by knowing
// its address, which is why this screen lets you paste one.

import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  ActivityIndicator,
  FlatList,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  Hop,
  HopAddress,
  HopNode,
  HopMessage,
  bytesToUtf8,
  toBase64,
} from '@hop-mesh/react-native';
import {connectLoopback, Loopback} from './src/loopback';
import {connectRelay, RelayLink, RelayState} from './src/relayBearer';
import {
  messageMeta,
  platformLabel,
  shortAddress,
  statusText,
  transportIcon,
} from './src/demoFormat';

// React Native ships no Node types and this app does not pull in @types/node, so `process` has no
// type here. Declare exactly the one field that is read.
declare const process: {env: {HOP_RELAY_URL?: string}};

// Where to dial by default. Read once, at module scope, and NOT reliable on a device: React Native's
// setUpGlobals defines `process.env` carrying NODE_ENV only, and Metro's inline plugin substitutes
// exactly `process.env.NODE_ENV` and `__DEV__`, nothing else. So this picks up an override under Jest
// or any bundler that inlines it, and falls back to the production relay on a plain device build.
// That is why the URL is editable on screen: pointing two phones at a relay on a LAN address is a
// normal thing to want, and it must not need a rebuild.
const RELAY_URL = process.env.HOP_RELAY_URL ?? 'wss://relay.hopme.sh/';

type Received = {
  id: string;
  from: string;
  body: string;
  meta: string;
};

// A peer as the UI knows it. `kind` is how the peer is reachable AT ALL, which is the distinction a
// human in front of this screen actually needs: the loopback peer is inside this process and proves
// nothing about the network, while a relay peer is another node that packets have to leave the device
// to reach. `transport` stays the native demos' vocabulary so the row glyph matches theirs.
type Peer = {
  address: string;
  label: string;
  transport: 'ble' | 'lan' | 'relay' | 'unknown';
  kind: 'loopback' | 'relay';
};

export default function App(): React.JSX.Element {
  const [status, setStatus] = useState<string>('starting');
  const [error, setError] = useState<string | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [peers, setPeers] = useState<Peer[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [received, setReceived] = useState<Received[]>([]);
  const [sendState, setSendState] = useState<string | null>(null);
  const [relayState, setRelayState] = useState<RelayState>('connecting');
  const [relayUrl, setRelayUrl] = useState(RELAY_URL);
  const [relayDraft, setRelayDraft] = useState(RELAY_URL);
  const [relayNote, setRelayNote] = useState<string | null>(null);
  const [peerDraft, setPeerDraft] = useState('');
  const [peerNote, setPeerNote] = useState<string | null>(null);

  const self = useRef<HopNode | null>(null);
  const peer = useRef<HopNode | null>(null);
  const wire = useRef<Loopback | null>(null);
  const relay = useRef<RelayLink | null>(null);

  const dialRelay = useCallback(async (url: string) => {
    const node = self.current;
    if (node == null) {
      return;
    }
    // Drop any previous link first. Two relay links on one node would both be dialer links, and the
    // old socket would keep draining packets meant for the new one.
    const previous = relay.current;
    relay.current = null;
    if (previous != null) {
      await previous.close().catch(() => {});
    }
    setRelayNote(null);
    setRelayState('connecting');
    // The URL shown is the one being used, including while a dial is failing: leaving the previous
    // URL on screen after tearing its link down would name a link that no longer exists.
    setRelayUrl(url);
    try {
      const link = await connectRelay(node, url, (state, detail) => {
        setRelayState(state);
        if (detail != null) {
          setRelayNote(detail);
        }
      });
      relay.current = link;
      setRelayState(link.state());
    } catch (e) {
      // A relay that is not there is visible here rather than a spinner that never resolves.
      setRelayState('down');
      setRelayNote(String(e));
    }
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        // Ephemeral on purpose: a demo should not leave a keystore behind, and Hop.open's persistent
        // path needs a writable db path that differs per platform. isPersistent() would report false
        // here anyway, so this is the honest choice rather than a silently ephemeral "persistent" node.
        const mine = await Hop.ephemeral();
        const other = await Hop.ephemeral();
        if (cancelled) {
          await mine.close();
          await other.close();
          return;
        }
        self.current = mine;
        peer.current = other;

        await mine.setName('This device');
        await other.setName('Loopback peer');

        const [myAddr, peerAddr] = await Promise.all([mine.address(), other.address()]);

        // Subscribe before the pump starts, or the first inbound message can land before there is a
        // listener and simply never appear.
        mine.onMessage(async (m: HopMessage) => {
          // bytesToUtf8 comes from the SDK. TextDecoder is not in React Native's lib types.
          const body = bytesToUtf8(m.body);
          // Resolved BEFORE setReceived, because the updater passed to a React setState is not async
          // and cannot await. `secured` is per-peer state, not a field on the message.
          const secured = await mine.isSecured(m.from);
          setReceived(prev => [
            {
              // toBase64 from the SDK: a stable key without pulling in node's Buffer, which RN lacks.
              id: toBase64(m.id),
              from: m.from,
              body,
              meta: messageMeta(m.hops, secured),
            },
            ...prev,
          ]);
          // Accept it, or the core repeats it on every poll.
          await mine.acceptInbox(m.id);
        });

        // Both ends must publish a prekey bundle before an untraceable send can seal to them.
        await Promise.all([mine.publishPrekey(), other.publishPrekey()]);

        wire.current = await connectLoopback(
          {node: mine, link: 1},
          {node: other, link: 2},
        );

        await Promise.all([mine.start(250), other.start(250)]);

        // The stand-in peer echoes nothing; it exists so this device has somewhere real to send.
        setAddress(myAddr);
        setPeers([
          {
            address: peerAddr,
            label: `${platformLabel('unknown')} loopback peer, in this process`,
            transport: 'unknown',
            kind: 'loopback',
          },
        ]);
        setSelected(peerAddr);
        setStatus('running');

        // Dialed after the screen is usable, and deliberately not awaited: an unreachable relay must
        // not stop the loopback path from working, and the relay's own state is on screen.
        void dialRelay(RELAY_URL);
      } catch (e) {
        setError(String(e));
        setStatus('failed');
      }
    })();

    return () => {
      cancelled = true;
      wire.current?.stop();
      void relay.current?.close();
      void self.current?.stop();
      void peer.current?.stop();
      void self.current?.close();
      void peer.current?.close();
    };
  }, [dialRelay]);

  const addPeer = useCallback(async () => {
    const typed = peerDraft.trim();
    if (typed.length === 0) {
      setPeerNote('paste an address first');
      return;
    }
    if (typed === address) {
      setPeerNote('that is this device, not a peer');
      return;
    }
    if (peers.some(p => p.address === typed)) {
      setPeerNote('already in the list');
      return;
    }
    try {
      // Real validation, by the same base58 decoder the native SDKs use: it returns null for anything
      // that is not exactly a 32-byte address. Adding an unparseable string would produce a peer row
      // that silently never receives anything.
      const decoded = await HopAddress.fromBase58(typed);
      if (decoded == null) {
        setPeerNote('not a Hop address: base58 of 32 bytes expected');
        return;
      }
    } catch (e) {
      setPeerNote(`could not read that address: ${String(e)}`);
      return;
    }
    setPeers(prev => [
      ...prev,
      {address: typed, label: 'Relay peer, another device', transport: 'relay', kind: 'relay'},
    ]);
    setSelected(typed);
    setPeerDraft('');
    setPeerNote('added');
  }, [address, peerDraft, peers]);

  const send = useCallback(async () => {
    const node = self.current;
    if (!node || !selected || draft.trim().length === 0) {
      return;
    }
    setSendState('sending');
    try {
      const id = await node.send({to: selected, body: draft});
      if (id == null) {
        setSendState('send failed');
        return;
      }
      setDraft('');
      const s = await node.status(id);
      setSendState(
        statusText({
          delivered: s.delivered,
          relayed: s.relayed,
          forwardHops: s.forwardHops,
        }),
      );
    } catch (e) {
      setSendState(`send failed: ${String(e)}`);
    }
  }, [draft, selected]);

  if (status === 'starting') {
    return (
      <SafeAreaView style={styles.center} testID="screen-loading">
        <ActivityIndicator />
        <Text style={styles.dim}>starting node</Text>
      </SafeAreaView>
    );
  }

  if (status === 'failed') {
    // Visibly unavailable rather than a silent no-op.
    return (
      <SafeAreaView style={styles.center} testID="screen-error">
        <Text style={styles.err} testID="error-text">
          {error}
        </Text>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.root} testID="screen-main">
      <StatusBar barStyle="dark-content" />
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={styles.h1}>HopDemo</Text>

        <Text style={styles.h2}>This device</Text>
        <Text style={styles.mono} testID="own-address" selectable>
          {address}
        </Text>
        <Text style={styles.dim} testID="own-address-short">
          {address ? shortAddress(address) : ''}
        </Text>
        {/* The native demos render this address as a scannable QR. RN has no QR renderer here, so the
            address is selectable text and this line says why, rather than showing a blank box. */}
        <Text style={styles.dim} testID="qr-unavailable">
          QR display unavailable in this build: no QR renderer bundled
        </Text>

        <Text style={styles.h2}>Relay</Text>
        {/* What `up` means, exactly: the socket is open and the core is driving the link. It does NOT
            mean the relay accepted this node, because the bearer carries opaque bytes and cannot read
            the protocol. A message arriving is the only proof of that. */}
        <Text style={styles.dim} testID="relay-note">
          A real bearer to a real relay: one core packet per WebSocket binary frame. This is how a node
          on another device reaches this one. Status covers the socket and the link, not the handshake.
        </Text>
        <Text style={styles.mono} testID="relay-status">
          {relayState}
        </Text>
        <Text style={styles.mono} testID="relay-url" selectable>
          {relayUrl}
        </Text>
        <TextInput
          testID="relay-url-input"
          style={styles.input}
          value={relayDraft}
          onChangeText={setRelayDraft}
          placeholder="wss://relay.hopme.sh/"
          autoCapitalize="none"
          autoCorrect={false}
        />
        <TouchableOpacity
          testID="relay-connect-button"
          style={styles.btn}
          onPress={() => {
            void dialRelay(relayDraft.trim());
          }}>
          <Text style={styles.btnText}>Connect relay</Text>
        </TouchableOpacity>
        {relayNote ? (
          <Text style={styles.warn} testID="relay-error">
            {relayNote}
          </Text>
        ) : null}

        <Text style={styles.h2}>People nearby</Text>
        <Text style={styles.dim} testID="bearer-note">
          No radio bearer in the React Native SDK, so nothing here is discovered: no BLE, no LAN. The
          first peer is an in-process node, and a peer on another device is reached by pasting its
          address below and carrying the bundle over the relay.
        </Text>
        {peers.length === 0 ? (
          <Text style={styles.dim} testID="peers-empty">
            nobody nearby
          </Text>
        ) : (
          <FlatList
            testID="peers-list"
            scrollEnabled={false}
            data={peers}
            keyExtractor={p => p.address}
            renderItem={({item, index}) => (
              // testID is index-based on purpose. A test cannot know a peer's address before it renders,
              // so an address-keyed id is unaddressable from a test; the address is exposed as its own
              // element below for any test that needs to read it.
              <TouchableOpacity
                testID={`peer-row-${index}`}
                style={[styles.row, selected === item.address && styles.rowOn]}
                onPress={() => setSelected(item.address)}>
                <Text style={styles.rowIcon}>{transportIcon(item.transport)}</Text>
                <View>
                  <Text style={styles.rowTitle}>{item.label}</Text>
                  <Text style={styles.dim} testID={`peer-address-${index}`}>
                    {shortAddress(item.address)}
                  </Text>
                  {/* A word, not the glyph: how this peer is reachable is the one thing a human, and a
                      test, must not have to infer from an icon. */}
                  <Text style={styles.dim} testID={`peer-transport-${index}`}>
                    {item.kind}
                  </Text>
                </View>
              </TouchableOpacity>
            )}
          />
        )}

        <Text style={styles.h2}>Reach another device</Text>
        <Text style={styles.dim} testID="add-peer-note">
          Paste the full address shown under "This device" on the other phone. Without a radio bearer
          there is nothing to discover, so an address is how a peer is found.
        </Text>
        <TextInput
          testID="peer-address-input"
          style={styles.input}
          value={peerDraft}
          onChangeText={setPeerDraft}
          placeholder="base58 address from the other device"
          autoCapitalize="none"
          autoCorrect={false}
        />
        <TouchableOpacity testID="add-peer-button" style={styles.btn} onPress={addPeer}>
          <Text style={styles.btnText}>Add peer</Text>
        </TouchableOpacity>
        {peerNote ? (
          <Text style={styles.warn} testID="add-peer-status">
            {peerNote}
          </Text>
        ) : null}

        <Text style={styles.h2}>Send</Text>
        <TextInput
          testID="message-input"
          style={styles.input}
          value={draft}
          onChangeText={setDraft}
          placeholder="meet at dawn"
          autoCorrect={false}
        />
        <TouchableOpacity testID="send-button" style={styles.btn} onPress={send}>
          <Text style={styles.btnText}>Send</Text>
        </TouchableOpacity>
        {sendState ? (
          <Text style={styles.dim} testID="send-status">
            {sendState}
          </Text>
        ) : null}

        <Text style={styles.h2}>Received</Text>
        {received.length === 0 ? (
          <Text style={styles.dim} testID="messages-empty">
            nothing yet
          </Text>
        ) : (
          <FlatList
            testID="messages-list"
            scrollEnabled={false}
            data={received}
            keyExtractor={m => m.id}
            renderItem={({item, index}) => (
              // Index-based ids, newest first, matching the peer list's scheme: setReceived prepends,
              // so index 0 is the most recent arrival. The message id is a base64 blob a test cannot
              // know in advance, so it stays the list key and nothing more.
              <View style={styles.row} testID={`message-row-${index}`}>
                <View>
                  <Text style={styles.rowTitle} testID={`message-body-${index}`}>
                    {item.body}
                  </Text>
                  <Text style={styles.dim} testID={`message-from-${index}`}>
                    {shortAddress(item.from)} {item.meta}
                  </Text>
                </View>
              </View>
            )}
          />
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#fff'},
  center: {flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#fff'},
  body: {padding: 16, gap: 6},
  h1: {fontSize: 28, fontWeight: '700', marginBottom: 8},
  h2: {fontSize: 16, fontWeight: '600', marginTop: 18, marginBottom: 4},
  mono: {fontFamily: 'Courier', fontSize: 12},
  dim: {color: '#666', fontSize: 12},
  warn: {color: '#b00', fontSize: 12},
  err: {color: '#b00', fontSize: 13, padding: 20},
  row: {flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10},
  rowOn: {backgroundColor: '#eef4ff'},
  rowIcon: {fontFamily: 'Courier', fontWeight: '700', width: 18, textAlign: 'center'},
  rowTitle: {fontSize: 15},
  input: {borderWidth: 1, borderColor: '#ccc', borderRadius: 6, padding: 10, fontSize: 15},
  btn: {backgroundColor: '#1b64f2', borderRadius: 6, padding: 12, alignItems: 'center', marginTop: 8},
  btnText: {color: '#fff', fontWeight: '600'},
});
