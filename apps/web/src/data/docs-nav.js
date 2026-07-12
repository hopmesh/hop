// Left-sidebar navigation for the docs site. Grouped sections, top to bottom.
// Add items here as the docs grow.
export const docsNav = [
  {
    title: 'Getting started',
    items: [
      { label: 'Overview', href: '/docs/' },
      { label: 'Quickstart', href: '/docs/quickstart/' },
    ],
  },
  {
    title: 'Drivers',
    items: [
      { label: 'Build a driver', href: '/docs/build-a-driver/' },
      { label: 'iOS', href: '/docs/drivers/ios/' },
      { label: 'Android', href: '/docs/drivers/android/' },
      { label: 'macOS', href: '/docs/drivers/macos/' },
      { label: 'ESP32', href: '/docs/drivers/esp32/' },
      { label: 'Linux / server', href: '/docs/drivers/linux/' },
    ],
  },
  {
    title: 'API reference',
    items: [
      { label: 'Interface reference', href: '/docs/api/' },
    ],
  },
  {
    title: 'Reference',
    items: [
      { label: 'Protocol stack', href: '/protocol/' },
      { label: 'Pricing', href: '/pricing/' },
      { label: 'FAQ', href: '/faq/' },
    ],
  },
];
