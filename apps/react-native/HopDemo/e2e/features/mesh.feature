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
  # @multi-device cannot be proven on one device, because a simulator has no radio and Detox drives a
  # single app instance. Those scenarios are specifications, and they SKIP with a stated reason rather
  # than passing. A scenario that appears to prove a relay while running alone would be worse than
  # having no test, so none of them asserts anything under Detox.

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
