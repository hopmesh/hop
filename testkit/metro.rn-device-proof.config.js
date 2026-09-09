'use strict';

// Serve the testkit receiver entry when the installed HopDemo debug APK asks Metro for index.bundle.
const fs = require('fs');
const path = require('path');
const {createRequire} = require('module');
const appRoot = path.resolve(__dirname, '../apps/react-native/HopDemo');
const repoRoot = path.resolve(__dirname, '..');
const appRequire = createRequire(path.join(appRoot, 'metro.config.js'));
const {getDefaultConfig, mergeConfig} = appRequire('@react-native/metro-config');

const bearer = process.env.RN_PROOF_BEARER;
if (bearer !== 'ble' && bearer !== 'lan') {
  throw new Error('RN_PROOF_BEARER must be ble or lan');
}
const entry = `/testkit/rn-device-proof-${bearer}-entry.bundle`;

const base = getDefaultConfig(repoRoot);
module.exports = mergeConfig(base, {
  projectRoot: repoRoot,
  watchFolders: [
    appRoot,
    path.resolve(repoRoot, 'sdk/react-native'),
    ...(fs.existsSync(path.join(appRoot, 'node_modules')) ? [fs.realpathSync(path.join(appRoot, 'node_modules'))] : []),
  ],
  resolver: {
    disableHierarchicalLookup: true,
    nodeModulesPaths: [path.join(appRoot, 'node_modules')],
    extraNodeModules: {
      react: path.join(appRoot, 'node_modules/react'),
      'react-native': path.join(appRoot, 'node_modules/react-native'),
      '@hop-mesh/react-native': path.join(appRoot, 'node_modules/@hop-mesh/react-native'),
      '@babel/runtime': path.join(appRoot, 'node_modules/@babel/runtime'),
    },
  },
  server: {
    rewriteRequestUrl(url) {
      return url.replace(/^\/index\.bundle/, entry);
    },
  },
});
