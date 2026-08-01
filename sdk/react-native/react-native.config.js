// React Native autolinking config for @hop-mesh/react-native. It tells the RN CLI where the native
// module lives on each platform so a consuming app links it without manual steps (pod install on iOS,
// a Gradle sync on Android).
module.exports = {
  dependency: {
    platforms: {
      ios: {
        podspecPath: __dirname + "/HopMesh.podspec",
      },
      android: {
        sourceDir: "./android",
        packageImportPath: "import sh.hop.reactnative.HopMeshPackage;",
        packageInstance: "new HopMeshPackage()",
      },
    },
  },
};
