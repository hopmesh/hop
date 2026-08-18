// HopDemo, React Native. A port of the two native HopDemo apps (apps/apple/HopDemo, SwiftUI, and
// apps/android/HopDemo, Compose) onto @hop-mesh/react-native, so one codebase exercises the bridge on
// both platforms.
//
// HOW THIS DIFFERS FROM THE NATIVE DEMOS, and it matters.
//
// The native demos get their radios from drivers/apple/HopDriver and drivers/android/hop-driver, which
// own the BLE, LAN and relay bearers. @hop-mesh/react-native ships NO bearer: its surface is
// linkUp / bytesReceived / onOutgoing, so the app is responsible for moving packets. There is therefore
// no way for this app to reach a second physical device today.
//
// So instead of pretending, it runs TWO nodes in-process and connects them with src/loopback.ts. This
// device is "you"; the second node stands in for a peer. Everything between them is real: real Rust
// core, real sealing, real inbox. A message shown as received here genuinely round-tripped through
// hop-core. What it does not cover is radio discovery and true multi-device relay, and the UI says so
// rather than implying a mesh that is not there.

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
import {Hop, HopNode, HopMessage, bytesToUtf8, toBase64} from '@hop-mesh/react-native';
import {connectLoopback, Loopback} from './src/loopback';
import {
  messageMeta,
  platformLabel,
  shortAddress,
  statusText,
  transportIcon,
} from './src/demoFormat';

type Received = {
  id: string;
  from: string;
  body: string;
  meta: string;
};

// A peer as the UI knows it. The native demos label rows by device model under "People nearby"; the
// loopback peer is labelled for what it actually is so nobody reads it as a discovered device.
type Peer = {
  address: string;
  label: string;
  transport: 'ble' | 'lan' | 'relay' | 'unknown';
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

  const self = useRef<HopNode | null>(null);
  const peer = useRef<HopNode | null>(null);
  const wire = useRef<Loopback | null>(null);

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
            label: `${platformLabel('unknown')} loopback peer`,
            transport: 'unknown',
          },
        ]);
        setSelected(peerAddr);
        setStatus('running');
      } catch (e) {
        setError(String(e));
        setStatus('failed');
      }
    })();

    return () => {
      cancelled = true;
      wire.current?.stop();
      void self.current?.stop();
      void peer.current?.stop();
      void self.current?.close();
      void peer.current?.close();
    };
  }, []);

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

        <Text style={styles.h2}>People nearby</Text>
        <Text style={styles.dim} testID="bearer-note">
          No radio bearer in the React Native SDK. The peer below is an in-process node, so delivery is
          real but discovery is not.
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
                </View>
              </TouchableOpacity>
            )}
          />
        )}

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
            renderItem={({item}) => (
              <View style={styles.row} testID={`message-${item.id}`}>
                <View>
                  <Text style={styles.rowTitle}>{item.body}</Text>
                  <Text style={styles.dim}>
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
  err: {color: '#b00', fontSize: 13, padding: 20},
  row: {flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10},
  rowOn: {backgroundColor: '#eef4ff'},
  rowIcon: {fontFamily: 'Courier', fontWeight: '700', width: 18, textAlign: 'center'},
  rowTitle: {fontSize: 15},
  input: {borderWidth: 1, borderColor: '#ccc', borderRadius: 6, padding: 10, fontSize: 15},
  btn: {backgroundColor: '#1b64f2', borderRadius: 6, padding: 12, alignItems: 'center', marginTop: 8},
  btnText: {color: '#fff', fontWeight: '600'},
});
