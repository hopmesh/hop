const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

// @hop-mesh/react-native is consumed by local path (`file:../../../sdk/react-native`), so npm links it
// into node_modules as a symlink pointing OUT of this project. Metro's default watchFolders is the project
// root alone and it does not follow a symlink outside it, so without this the packager answers HTTP 500
// with "Unable to resolve module @hop-mesh/react-native" and the app shows a red screen on device. The APK
// still builds and the process still starts, which is exactly why a build or a pidof check is not evidence
// the app works.
const sdk = path.resolve(__dirname, '../../../sdk/react-native');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = {
  watchFolders: [sdk],
  resolver: {
    // The SDK carries its own node_modules for building itself. Left alone, Metro would resolve react and
    // react-native from there as well as from here and bundle two copies, which breaks hooks with an
    // "Invalid hook call". Pinning both to this app's copies keeps one of each in the bundle.
    extraNodeModules: {
      react: path.resolve(__dirname, 'node_modules/react'),
      'react-native': path.resolve(__dirname, 'node_modules/react-native'),
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
