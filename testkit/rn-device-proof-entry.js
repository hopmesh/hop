'use strict';

// Test-only JavaScript entry loaded by Metro into the built React Native demo APK. It runs one Hop
// node, keeps the JavaScript transport seam unused, and logs receiver evidence to the device log.
const pathPrefix = '../apps/react-native/HopDemo/node_modules/';
const React = require(pathPrefix + 'react');
const {AppRegistry, Text, View} = require(pathPrefix + 'react-native');
const {
  Hop,
  bytesToUtf8,
} = require(pathPrefix + '@hop-mesh/react-native');

const APP_SECRET = new Uint8Array(32).fill(0x48);
const DB_PATH = '/data/user/0/com.hopdemo/files/rn-device-bearer-proof.db';
let displayLine = 'starting';

function timestamp() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`${timestamp()} RNPROOF ${message}`);
}

async function startProof() {
  try {
    const bearer = global.__RN_PROOF_BEARER__;
    if (bearer !== 'ble' && bearer !== 'lan') {
      throw new Error(`invalid injected bearer ${String(bearer)}`);
    }
    const node = await Hop.open({dbPath: DB_PATH, appSecret: APP_SECRET});
    if (node == null) {
      throw new Error(`could not open ${DB_PATH}`);
    }
    node.onMessage(async message => {
      const body = bytesToUtf8(message.body);
      const accepted = await node.acceptInbox(message.id);
      log(`receipt bearer=${bearer} nonce=${body} from=${message.from} accepted=${accepted}`);
      displayLine = `received ${body}`;
    });
    await node.setName(`RN Pixel ${bearer.toUpperCase()} proof`);
    await node.setBearerEnabled('ble', bearer === 'ble');
    await node.setBearerEnabled('lan', bearer === 'lan');
    await node.publishPrekey();
    await node.start(100);
    const address = await node.address();
    const snapshot = await node.bearerSnapshot();
    displayLine = `${bearer} ${address}`;
    log(`ready bearer=${bearer} self=${address} states=${JSON.stringify(snapshot.states)}`);
  } catch (error) {
    displayLine = `fatal ${String(error)}`;
    log(`fatal error=${String(error)}`);
  }
}

function ProofApp() {
  return React.createElement(
    View,
    {style: {flex: 1, padding: 24, backgroundColor: '#ffffff'}},
    React.createElement(Text, {testID: 'rn-proof-state'}, displayLine),
  );
}

log('bundle loaded');
AppRegistry.registerComponent('HopDemo', () => ProofApp);
void startProof();
