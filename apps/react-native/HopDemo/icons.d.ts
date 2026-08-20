// Type shim for react-native-vector-icons, which ships without its own declarations. The icon set is
// FontAwesome6 to match the glyph style of both native demos' tab bars and row actions.
declare module 'react-native-vector-icons/FontAwesome6' {
  import type {FunctionComponent} from 'react';
  const Icon: FunctionComponent<{
    name: string;
    size?: number;
    color?: string;
    style?: object;
  }>;
  export default Icon;
}
