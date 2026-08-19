Feature: Carrying a message over the Hop mesh
  In order to reach someone without infrastructure
  As a person holding a device
  I want to see who is nearby and send them a message

  # Scenarios are split by whether ONE device can honestly prove them.
  #
  # @single-device runs under Detox on a simulator or emulator. The app pairs two in-process nodes over a
  # loopback bearer, so send and receive are real: the bytes go through the Rust core, get sealed, and
  # arrive through the inbox. That is worth automating.
  #
  # @multi-device covers the BLE mesh, which still cannot be proven at all: the React Native SDK ships no
  # radio bearer and no discovery surface, so there is nothing to drive. Those scenarios are specifications
  # and they SKIP with a stated reason rather than passing.
  #
  # @device-pair covers what two real devices CAN prove today, a message crossing them through a relay.
  # Those do assert, because two devices really are driven. See the block at the bottom.

  Background:
    Given the app is running

  @single-device @smoke
  Scenario: My device has an address others could reach
    Then I should see my own address
    And my address should be a base58 address

  @single-device
  Scenario: The app is honest that it has no radio
    Then I should be told discovery is unavailable without a bearer

  @single-device
  Scenario: The app is honest that it cannot draw a QR code
    Then I should be told the QR code is unavailable

  @single-device @smoke
  Scenario: Someone reachable appears in my list
    Then I should see 1 person I can reach

  @single-device @smoke
  Scenario: A message I send arrives
    When I send "meet at dawn" to the person I can reach
    Then the message should be reported as on its way

  @single-device
  Scenario: An empty message is not sent
    When I send "" to the person I can reach
    Then no delivery should be reported

  @single-device
  Scenario Outline: Messages of different shapes all send
    When I send "<body>" to the person I can reach
    Then the message should be reported as on its way

    Examples: ordinary and awkward bodies
      | body                       |
      | meet at dawn               |
      | 12:30 by the north gate    |
      | emoji and accents, cafe    |

  # ---------------------------------------------------------------------------------------------------
  # Specifications that need real hardware. Tagged so they skip, never pass, under Detox.
  # ---------------------------------------------------------------------------------------------------

  @multi-device
  Scenario: A nearby phone appears by its device name
    Given another phone running HopDemo is within Bluetooth range
    Then I should see that phone listed by its device model name

  @multi-device
  Scenario: A message reaches a second phone
    Given another phone running HopDemo is within Bluetooth range
    When I send "meet at dawn" to that phone
    Then that phone should show the message in its chat

  @multi-device
  Scenario: A phone in the middle relays for two that cannot hear each other
    Given three phones in a line where the outer two are out of range of each other
    When the first phone sends "meet at dawn" to the third
    Then the third phone should receive it
    And the middle phone should have carried it

  # ---------------------------------------------------------------------------------------------------
  # Two REAL devices, through a real relay. These ASSERT.
  #
  # Run by `npm run e2e:pair`, which starts one Detox process per device, because Detox drives a single
  # app instance per process. Both processes execute this scenario and each step branches on its role, so
  # the story reads as one exchange while each side only asserts what its own device shows.
  #
  # Excluded from every default profile, so a developer with no hardware gets a green run that never
  # claimed to cover this. The Background applies here too and is harmless: it waits for this device's
  # own address before the cross-process barrier.
  #
  # The body is not a bare literal. Each step appends the run id, so an assertion cannot be satisfied by
  # a message left on screen by an earlier run.
  # ---------------------------------------------------------------------------------------------------

  @device-pair
  Scenario: A message crosses two real devices through a relay
    Given both devices are paired for this run
    And this device is connected to the relay under test
    And the two devices have exchanged addresses
    When the sending device sends "meet at dawn" to the receiving device
    Then the receiving device shows the same message
    And the receiving device attributes it to the sending device
    And both devices agree the message crossed
