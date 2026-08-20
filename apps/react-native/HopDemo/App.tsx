// HopDemo, React Native. The port of the native demos (apps/apple SwiftUI, apps/android Compose), not a
// sketch beside them: the same four tabs (Chats, Relays, Web, Status), the same chat thread with bubbles
// and a meta line per message, the same pulsing "awaiting peers" indicator, and the Hop signal green on
// the buttons, from src/theme.ts. Layout rules that cost a round trip on a real device are baked in here:
// real safe areas via react-native-safe-area-context on every edge (the react-native built-in
// SafeAreaView is iOS-only and a no-op on Android), and a keyboard-aware composer (measured keyboard
// height paid as scroll padding, the focused field scrolled into view, taps persisted while typing).
//
// What this app cannot yet do, it says on screen instead of faking: see the Web tab and the QR row.

import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  FlatList,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
// SafeAreaView comes from react-native-safe-area-context, NOT from react-native. The built-in one is
// iOS-only, a no-op on Android, and deprecated, so with edge-to-edge enabled by default on modern Android
// it silently does nothing and this screen drew its first line above the status bar clock on a Pixel 7.
import {SafeAreaProvider, SafeAreaView} from 'react-native-safe-area-context';
// Font Awesome glyphs, the same icon set both native demos use for their tab bar and row actions.
import Icon from 'react-native-vector-icons/FontAwesome6';
import {
  Hop,
  HopAddress,
  HopMessage,
  HopNode,
  bytesToUtf8,
  toBase64,
} from '@hop-mesh/react-native';
import {connectLoopback, Loopback} from './src/loopback';
import {connectRelay, RelayLink, RelayState} from './src/relayBearer';
import {hop, type as typo} from './src/theme';
import {
  messageMeta,
  platformLabel,
  shortAddress,
  statusText,
} from './src/demoFormat';

declare const process: {env: {HOP_RELAY_URL?: string}};

const RELAY_URL = process.env.HOP_RELAY_URL ?? 'wss://relay.hopme.sh/';

type Peer = {address: string; label: string; transport: string; kind: string};
// One row in the chat thread. `mine` decides the side and the bubble color, exactly like the native
// demos' incoming/mine split.
type Row = {
  id: string;
  from: string;
  body: string;
  mine: boolean;
  meta: string;
};

export default function App(): React.JSX.Element {
  const [status, setStatus] = useState<string>('starting');
  const [error, setError] = useState<string | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [peers, setPeers] = useState<Peer[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [thread, setThread] = useState<Row[]>([]);
  const [sendState, setSendState] = useState<string | null>(null);
  const [sentAt, setSentAt] = useState<number | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [relayState, setRelayState] = useState<RelayState>('connecting');
  const [relayUrl, setRelayUrl] = useState(RELAY_URL);
  const [relayDraft, setRelayDraft] = useState(RELAY_URL);
  const [relayNote, setRelayNote] = useState<string | null>(null);
  const [peerDraft, setPeerDraft] = useState('');
  const [peerNote, setPeerNote] = useState<string | null>(null);
  const [tab, setTab] = useState(0);

  // Held so focusing a text input can bring it, and the button under it, above the keyboard. Avoiding the
  // keyboard is only half the job: a composer near the bottom of a long ScrollView is still unreachable if
  // focusing it does not scroll.
  const scrollRef = useRef<React.ComponentRef<typeof ScrollView> | null>(null);

  // MEASURED keyboard height, applied as bottom padding on the scroll content.
  //
  // This is here because the obvious answers do not work on this platform. React Native 0.87 turns on
  // edge-to-edge by default on Android, and under edge-to-edge the window no longer resizes for the
  // keyboard, so the manifest's android:windowSoftInputMode="adjustResize" stops lifting anything.
  // KeyboardAvoidingView with behavior 'height' then double-counts and squashes the layout. Measured on a
  // physical Pixel 7: with only those two in place the keyboard opened over the composer and the Send
  // button and the view did not move at all.
  //
  // Padding the content by the real keyboard height gives the ScrollView somewhere to scroll TO, which is
  // what makes both the focused field and the button under it reachable.
  const [keyboardInset, setKeyboardInset] = useState(0);
  useEffect(() => {
    const show = Keyboard.addListener(
      Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow',
      e => setKeyboardInset(e.endCoordinates.height),
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

  // Bring a focused field, and the button beneath it, above the keyboard. The delay lets the keyboard frame
  // land first: scrolling before the inset is applied computes against the old content height and stops short.
  const revealComposer = useCallback(() => {
    setTimeout(() => scrollRef.current?.scrollToEnd({animated: true}), 180);
  }, []);

  const self = useRef<HopNode | null>(null);
  const peer = useRef<HopNode | null>(null);
  const wire = useRef<Loopback | null>(null);
  const relay = useRef<RelayLink | null>(null);

  // The "Awaiting peers · Ns" timer, ticking only while a send is in flight, like the native
  // SendingIndicator's live counter.
  useEffect(() => {
    if (sentAt == null) {
      return;
    }
    setElapsed(0);
    const t = setInterval(() => setElapsed(Math.floor((Date.now() - sentAt) / 1000)), 1000);
    return () => clearInterval(t);
  }, [sentAt]);

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
          // Resolved BEFORE setThread, because the updater passed to a React setState is not async
          // and cannot await. `secured` is per-peer state, not a field on the message.
          const secured = await mine.isSecured(m.from);
          setThread(prev => [
            ...prev,
            {
              // toBase64 from the SDK: a stable key without pulling in node's Buffer, which RN lacks.
              id: toBase64(m.id),
              from: m.from,
              body,
              mine: false,
              meta: messageMeta(m.hops, secured),
            },
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
        // Land on the Chats LIST, like both native demos, not inside the loopback thread: the old
        // single-screen app auto-selected its only peer, and keeping that made this port open mid-chat,
        // which is not how a chat app starts.
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
    setSentAt(Date.now());
    try {
      const id = await node.send({to: selected, body: draft});
      if (id == null) {
        setSendState('send failed');
        setSentAt(null);
        return;
      }
      const body = draft;
      setDraft('');
      const s = await node.status(id);
      const meta = statusText({
        delivered: s.delivered,
        relayed: s.relayed,
        forwardHops: s.forwardHops,
      });
      // Own messages join the thread like the native demos' chat: bubble on the right, meta beneath.
      setThread(prev => [
        ...prev,
        {id: toBase64(id), from: address ?? '', body, mine: true, meta},
      ]);
      setSentAt(null);
      setSendState(meta);
    } catch (e) {
      setSendState(`send failed: ${String(e)}`);
      setSentAt(null);
    }
  }, [draft, selected, address]);

  if (status === 'starting') {
    return (
      <SafeAreaProvider>
        <SafeAreaView style={styles.center} edges={['top', 'bottom']} testID="screen-loading">
          <ActivityIndicator />
          <Text style={styles.dim}>starting node</Text>
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

  if (status === 'failed') {
    // Visibly unavailable rather than a silent no-op.
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

  const selectedPeer = peers.find(p => p.address === selected) ?? null;

  // The bottom tab bar both native demos use: Chats, Relays, Web, Status, each a Font Awesome glyph in
  // the Hop green when selected.
  const Tab = ({id, icon, label}: {id: number; icon: string; label: string}) => (
    <TouchableOpacity
      testID={`tab-${label.toLowerCase()}`}
      style={styles.tabItem}
      onPress={() => setTab(id)}>
      <Icon name={icon} size={20} color={tab === id ? hop.accent : hop.secondary} />
      <Text style={[styles.tabLabel, {color: tab === id ? hop.accent : hop.secondary}]}>{label}</Text>
    </TouchableOpacity>
  );

  return (
    // Safe areas on all four edges, from react-native-safe-area-context so it actually applies on Android.
    // KeyboardAvoidingView so the composer and the Send button stay above the soft keyboard: the keyboard
    // used to cover both, which made the app unusable for its one job and also made a Detox tap land on
    // nothing. `padding` is right on iOS; on Android the manifest's adjustResize does the resize and adding
    // `height` on top of it double-counts and squashes the layout.
    <SafeAreaProvider>
      <SafeAreaView
        style={styles.root}
        edges={['top', 'bottom', 'left', 'right']}
        testID="screen-main">
        <StatusBar barStyle="dark-content" />
        <KeyboardAvoidingView
          style={styles.fill}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          {/* The scroll container is addressable on purpose. screen-main is the SafeAreaView, its PARENT,
              and a Detox swipe there does not reach this child: measured on a Pixel 7, eight slow upward
              swipes on screen-main left the screen pinned at the top. by.type('android.widget.ScrollView')
              is no use either, because peers-list and messages-list are FlatLists and render as scroll
              views too, so the matcher is ambiguous. A test that has to scroll a control into view needs
              this id.

              keyboardShouldPersistTaps keeps a tap on Send working while the keyboard is up, instead of
              being swallowed as a dismiss. automaticallyAdjustKeyboardInsets is the iOS half of the same
              job, and is ignored elsewhere. */}
          <ScrollView
            ref={scrollRef}
            testID="main-scroll"
            contentContainerStyle={[styles.screenBody, {paddingBottom: 24 + keyboardInset}]}
            keyboardShouldPersistTaps="handled"
            keyboardDismissMode="on-drag"
            automaticallyAdjustKeyboardInsets>
            {tab === 0 && !selectedPeer && (
              <ChatsTab
                peers={peers}
                peerDraft={peerDraft}
                setPeerDraft={setPeerDraft}
                peerNote={peerNote}
                addPeer={addPeer}
                onPick={setSelected}
              />
            )}
            {tab === 0 && selectedPeer && (
              <ChatThread
                peer={selectedPeer}
                thread={thread}
                sendState={sendState}
                elapsed={elapsed}
                onBack={() => setSelected(null)}
                draft={draft}
                setDraft={setDraft}
                revealComposer={revealComposer}
                send={send}
              />
            )}
            {tab === 1 && (
              <RelaysTab
                relayState={relayState}
                relayUrl={relayUrl}
                relayDraft={relayDraft}
                setRelayDraft={setRelayDraft}
                relayNote={relayNote}
                dial={() => dialRelay(relayDraft.trim())}
                revealComposer={revealComposer}
              />
            )}
            {tab === 2 && <WebTab />}
            {tab === 3 && <StatusTab address={address} />}
          </ScrollView>
        </KeyboardAvoidingView>
        <View style={styles.tabBar}>
          <Tab id={0} icon="comment" label="Chats" />
          <Tab id={1} icon="tower-broadcast" label="Relays" />
          <Tab id={2} icon="globe" label="Web" />
          <Tab id={3} icon="gear" label="Status" />
        </View>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

/// The Chats list: headline, add-by-address, and one row per reachable peer with the transport word and
/// the green reachability dot the native demos show.
function ChatsTab({
  peers,
  peerDraft,
  setPeerDraft,
  peerNote,
  addPeer,
  onPick,
}: {
  peers: Peer[];
  peerDraft: string;
  setPeerDraft: (s: string) => void;
  peerNote: string | null;
  addPeer: () => void;
  onPick: (address: string) => void;
}) {
  return (
    <View>
      <Text style={styles.headline}>Chats</Text>
      <Text style={styles.dim} testID="bearer-note">
        No radio bearer in the React Native SDK. The peer below is an in-process node, so delivery is
        real but discovery is not.
      </Text>

      <Text style={styles.h2}>Add by address</Text>
      <View style={styles.rowWrap}>
        <TextInput
          style={styles.inputFlex}
          testID="peer-address-input"
          value={peerDraft}
          onChangeText={setPeerDraft}
          onFocus={undefined}
          placeholder="base58 address"
          autoCorrect={false}
          autoCapitalize="none"
        />
        <TouchableOpacity style={styles.btnSmall} testID="add-peer-button" onPress={addPeer}>
          <Icon name="user-plus" size={14} color={hop.accentInk} />
          <Text style={styles.btnSmallText}>Add</Text>
        </TouchableOpacity>
      </View>
      {peerNote ? (
        <Text style={styles.err} testID="add-peer-status">
          {peerNote}
        </Text>
      ) : null}
      <Text style={styles.tiny} testID="add-peer-note">
        An empty name falls back to the address, like the native demos' Add Contact.
      </Text>

      <Text style={styles.h2}>People nearby</Text>
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
              style={styles.peerRow}
              onPress={() => onPick(item.address)}>
              <View style={styles.peerIcon}>
                <View
                  style={[styles.dot, {backgroundColor: item.kind === 'loopback' ? hop.active : hop.pulse}]}
                />
              </View>
              <View style={styles.inputFlex}>
                <Text style={styles.peerTitle}>{item.label}</Text>
                <Text style={styles.dim} testID={`peer-address-${index}`}>
                  {shortAddress(item.address)}
                </Text>
              </View>
              <Text style={styles.tiny} testID={`peer-transport-${index}`}>
                {item.kind}
              </Text>
              <Icon name="chevron-right" size={14} color={hop.tertiary} />
            </TouchableOpacity>
          )}
        />
      )}
    </View>
  );
}

/// One conversation: bubbles with a meta line each, the pulsing in-flight indicator, and the composer.
function ChatThread({
  peer,
  thread,
  sendState,
  elapsed,
  onBack,
  draft,
  setDraft,
  revealComposer,
  send,
}: {
  peer: Peer;
  thread: Row[];
  sendState: string | null;
  elapsed: number;
  onBack: () => void;
  draft: string;
  setDraft: (s: string) => void;
  revealComposer: () => void;
  send: () => void;
}) {
  return (
    <View>
      <View style={styles.chatHeader}>
        <TouchableOpacity testID="chat-back" onPress={onBack} style={styles.backBtn}>
          <Icon name="chevron-left" size={16} color={hop.accent} />
          <Text style={styles.backText}>Chats</Text>
        </TouchableOpacity>
        <Text style={styles.chatTitle} testID="chat-title" numberOfLines={1}>
          {peer.label}
        </Text>
        <Icon name="lock" size={13} color={hop.active} />
      </View>

      {thread.length === 0 ? (
        <Text style={styles.dim} testID="messages-empty">
          no messages yet
        </Text>
      ) : (
        <FlatList
          testID="messages-list"
          scrollEnabled={false}
          data={thread}
          keyExtractor={m => m.id}
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
                {item.mine ? item.meta : `${shortAddress(item.from)} · ${item.meta}`}
              </Text>
            </View>
          )}
        />
      )}

      {sendState === 'sending' ? <SendingIndicator elapsed={elapsed} /> : null}
      {/* Rendered for EVERY non-null state, including 'sending', not only once resolved: the status
          element must exist while the query is in flight, or a test asserting on it right after the tap
          finds nothing and reads that as the app never reporting. The indicator carries the live pulsing
          view; this line carries the state word. */}
      {sendState ? (
        <Text style={styles.dim} testID="send-status">
          {sendState}
        </Text>
      ) : null}

      <View style={styles.rowWrap}>
        <TextInput
          style={styles.inputFlex}
          testID="message-input"
          value={draft}
          onChangeText={setDraft}
          onFocus={revealComposer}
          placeholder={`Message ${peer.label}`}
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
  );
}

/// The native demos' in-flight status: a pulsing dot and a live "Awaiting peers · Ns" counter, conveying
/// "working on it, holding for a peer" rather than a static, alarming "Sending...".
function SendingIndicator({elapsed}: {elapsed: number}) {
  const pulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const a = Animated.loop(
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
    a.start();
    return () => a.stop();
  }, [pulse]);
  return (
    <View style={styles.pulseRow} testID="sending-indicator">
      <Animated.View style={[styles.pulseDot, {opacity: pulse}]} />
      <Text style={styles.meta}>Awaiting peers · {elapsed}s</Text>
    </View>
  );
}

/// The Relays tab: the live relay link state, the URL in use, and dial controls.
function RelaysTab({
  relayState,
  relayUrl,
  relayDraft,
  setRelayDraft,
  relayNote,
  dial,
  revealComposer,
}: {
  relayState: RelayState;
  relayUrl: string;
  relayDraft: string;
  setRelayDraft: (s: string) => void;
  relayNote: string | null;
  dial: () => void;
  revealComposer: () => void;
}) {
  const color = relayState === 'up' ? hop.active : relayState === 'down' ? hop.danger : hop.secondary;
  return (
    <View>
      <Text style={styles.headline}>Relays</Text>
      <View style={styles.relayRow}>
        <View style={[styles.dot, {backgroundColor: color}]} />
        <Text style={styles.body} testID="relay-status">
          {relayState}
        </Text>
      </View>
      <Text style={styles.monoSmall} testID="relay-url">
        {relayUrl}
      </Text>
      {relayNote ? (
        <Text style={styles.err} testID="relay-error">
          {relayNote}
        </Text>
      ) : null}
      <Text style={styles.tiny} testID="relay-note">
        The relay is a bearer: it carries opaque bytes and knows nothing about the protocol. A green
        state means the socket is up, not that a peer answered.
      </Text>
      <View style={styles.rowWrap}>
        <TextInput
          style={styles.inputFlex}
          testID="relay-url-input"
          value={relayDraft}
          onChangeText={setRelayDraft}
          onFocus={revealComposer}
          placeholder="host:port or wss://relay.hopme.sh/"
          autoCapitalize="none"
          autoCorrect={false}
        />
        <TouchableOpacity style={styles.btnSmall} testID="relay-connect-button" onPress={dial}>
          <Text style={styles.btnSmallText}>Connect</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

/// The Web tab. The native demos browse hops:// pages through the driver's proxy, which the React Native
/// SDK does not bridge, so this tab states that rather than rendering a browser that cannot fetch.
function WebTab() {
  return (
    <View>
      <Text style={styles.headline}>Web</Text>
      <Text style={styles.dim} testID="web-unavailable">
        hops:// browsing needs the Hop driver's proxy, which the React Native SDK does not bridge yet.
        The native demos carry this tab; this port says so instead of showing a browser that cannot
        fetch anything.
      </Text>
    </View>
  );
}

/// The Status tab: this device's address, and the honest unavailability notes.
function StatusTab({address}: {address: string | null}) {
  return (
    <View>
      <Text style={styles.headline}>Status</Text>
      <Text style={styles.h2}>This device</Text>
      <Text style={styles.mono} testID="own-address" selectable>
        {address}
      </Text>
      <Text style={styles.dim} testID="own-address-short">
        {address ? shortAddress(address) : ''}
      </Text>
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
  center: {flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: hop.bg},
  fill: {flex: 1},
  // paddingBottom leaves room for the composer and Send to sit clear of the keyboard and the home
  // indicator once the ScrollView is inset, rather than ending flush against them.
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

  tabBar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: hop.hairline,
    backgroundColor: hop.barBg,
  },
  tabItem: {flex: 1, alignItems: 'center', paddingVertical: 8, gap: 2},
  tabLabel: {fontSize: 10},

  chatHeader: {flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 10},
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

  relayRow: {flexDirection: 'row', alignItems: 'center', gap: 8, marginVertical: 4},

  rowWrap: {flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 6},
  inputFlex: {
    flex: 1,
    borderWidth: 1,
    borderColor: hop.hairline,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 8,
  },

  // The Hop signal green on the buttons, matching the native demos' accent-tinted actions.
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
