// The Hop design tokens, matched to the sibling native apps rather than invented here.
//
// ACCENT is the Hop signal green from the web site's tokens (apps/web/site/src/styles/global.css:
// `--accent: #2bf0a0; /* signal green */`, with `--accent-ink: #04130c` for text on it). The native demos
// tint their own bubbles with their platform accent at ~25% opacity and their buttons with the accent
// itself; this app does the same with the Hop green so all three read as one product.
//
// The bubble, indicator and status colors are lifted from the native apps verbatim:
//   incoming bubble   gray at ~20% opacity            (ContentView.swift:524, MainActivity.kt bubble bg)
//   mine bubble       accent at ~25% opacity          (ContentView.swift:524)
//   awaiting pulse    #FF9500, iOS system orange      (MainActivity.kt:309, SendingIndicator)
//   active dot        #34C759, iOS system green       (MainActivity.kt:816)

export const hop = {
  accent: '#2bf0a0', // signal green
  accentInk: '#04130c', // near-black green for text ON the accent
  accentDim: 'rgba(43, 240, 160, 0.25)', // my-message bubble, matching accentColor.opacity(0.25)
  bubbleIncoming: 'rgba(142, 142, 147, 0.2)', // system gray at 0.2, like Color.gray.opacity(0.2)
  pulse: '#FF9500', // the "awaiting peers" dot
  active: '#34C759', // the peer-online dot
  danger: '#FF3B30',
  bg: '#FFFFFF',
  fg: '#000000',
  secondary: 'rgba(60, 60, 67, 0.6)', // system secondary label
  tertiary: 'rgba(60, 60, 67, 0.3)', // system tertiary label
  hairline: 'rgba(60, 60, 67, 0.29)',
  barBg: 'rgba(249, 249, 249, 0.94)', // the translucent bar the natives use
};

// Font sizes follow the native demos' hierarchy: headline for screen titles, title for sections,
// body for content, caption2 for the meta line under a bubble.
export const type = {  // `as const` so fontWeight lands as the literal union RN's styles expect
  headline: {fontSize: 28, fontWeight: '700'} as const,
  title: {fontSize: 17, fontWeight: '600'} as const,
  body: {fontSize: 16},
  caption: {fontSize: 12},
  mono: {fontSize: 13, fontFamily: 'Menlo'},
};
