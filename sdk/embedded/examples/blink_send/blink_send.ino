// blink_send: the smallest honest Hop client for an ESP32.
//
// It opens a Hop node, prints its mesh address, ticks the core once a loop, sends a "chat/say" message
// to a peer when the button is pressed, and prints any message that arrives. The one piece this sketch
// does NOT provide is the radio: Hop moves opaque bytes, and YOU wire them to a bearer (BLE, LoRa,
// Wi-Fi). The TODO(bearer) markers below are where that glue goes. Until it is filled in the node runs
// and addresses messages, but nothing leaves the board.

#include <Arduino.h>
#include <Hop.h>

// The button that triggers a send (most dev boards route the BOOT button to GPIO 0).
static const int kButtonPin = 0;

// The peer you are messaging, as a base58 Hop address. Print the OTHER board's address() over serial
// and paste it here. The placeholder will not decode, so send() simply returns false until you set it.
static const char *kPeerAddress = "PASTE_A_PEER_ADDRESS_HERE";

static hop::Hop node;
static int lastButton = HIGH;

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(kButtonPin, INPUT_PULLUP);

  if (!node.begin()) {
    Serial.println("Hop: begin() failed (ABI mismatch or out of memory). Halting.");
    while (true) {
      delay(1000);
    }
  }
  node.setName("blink-send");

  // Print every message that arrives. Pointers are borrowed for this callback only, so copy to keep.
  node.onMessage([](const hop::Message &msg) {
    Serial.print("recv ");
    Serial.print(msg.service);
    Serial.print("/");
    Serial.print(msg.method);
    Serial.print(" -> ");
    Serial.write(msg.payload, msg.payload_len);
    Serial.println();
  });

  // Ship every outbound packet over your radio. Called from inside tick().
  node.onOutgoing([](uint64_t link, const uint8_t *data, size_t len) {
    (void)link;
    (void)data;
    (void)len;
    // TODO(bearer): transmit these `len` bytes over BLE / LoRa on the given `link`.
  });

  node.subscribe("chat");

  Serial.print("Hop address: ");
  Serial.println(node.address().c_str());

  // TODO(bearer): as your radio discovers a peer and a link forms, call:
  //   node.linkUp(linkId, hop::LinkRole::Dialer);   // or Acceptor on the side that accepted
  // and for each frame the radio receives:
  //   node.bytesReceived(linkId, frame, frameLen);
  // and when the link drops:
  //   node.linkDown(linkId);
}

void loop() {
  // Pump the node. tick() advances time, drains outbound to onOutgoing, and delivers arrivals to
  // onMessage. Call it often; once a loop is fine.
  node.tick(millis());

  // Send on a button press (falling edge, with a crude debounce).
  int button = digitalRead(kButtonPin);
  if (lastButton == HIGH && button == LOW) {
    bool queued = node.send(kPeerAddress, "chat", "say", std::string("hello from blink_send"));
    Serial.println(queued ? "sent chat/say" : "send failed (set kPeerAddress to a real address)");
    delay(50);
  }
  lastButton = button;

  delay(10);
}
