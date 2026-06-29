// HopRole — which side opened a bearer link (the Noise role). It lives in HopContract so bearers and
// the node both share it WITHOUT depending on libhop. The libhop mapping (to the C `HopLinkRole`)
// lives in Hop (HopNode.linkUp), keeping this module pure Swift.

/// Which side opened a bearer link (the Noise role).
public enum HopRole {
    case dialer    // we dialed out → Noise initiator
    case acceptor  // a peer connected in → Noise responder
}
