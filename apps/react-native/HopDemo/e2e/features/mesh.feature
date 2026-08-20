Feature: Carrying a message over the Hop mesh
  In order to reach someone without infrastructure
  As a person holding a device
  I want to see who is nearby and send them a message

  # Scenarios are split by whether ONE device can honestly prove them.
  #
  # @single-device proves local identity and UI contracts without inventing a peer. Discovery, radio
  # transport, and messages now come from the platform Hop driver, so a lone device may correctly show
  # no peers.
  #
  # @multi-device covers the BLE mesh on physical hardware. Those scenarios remain specifications under
  # Detox because its iOS support is simulator-only.
  #
  # @device-pair covers what two real devices can prove through their configured driver transports.
  # Those scenarios assert because two devices really are driven. See the block at the bottom.

  Background:
    Given the app is running

  @single-device @smoke
  Scenario: My device has an address others could reach
    Then I should see my own address
    And my address should be a base58 address

  @single-device
  Scenario: Discovery is backed by the platform driver
    Then I should be told discovery uses the platform driver

  @single-device
  Scenario: The app is honest that it cannot draw a QR code
    Then I should be told the QR code is unavailable


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
  # Two REAL devices, through the relay configured in the platform driver. These ASSERT.
  #
  # Run by `npm run e2e:pair`, which starts one Detox process per device, because Detox drives a single
  # app instance per process. Both processes execute this scenario and each step branches on its role, so
  # the story reads as one exchange while each side only asserts what its own device shows.
  #
  # Excluded from every default profile, so a developer with no hardware gets a green run that never
  # claimed to cover this. The pair steps open the Status and Chats tabs they need after the Background
  # confirms the main mesh UI is running.
  #
  # The body is not a bare literal. Each step appends the run id, so an assertion cannot be satisfied by
  # a message left on screen by an earlier run.
  # ---------------------------------------------------------------------------------------------------

  @device-pair
  Scenario: A message crosses two real devices through a relay
    Given both devices are paired for this run
    And the configured relay transport on this device is available
    And the two devices have exchanged addresses
    When the sending device sends "meet at dawn" to the receiving device
    Then the receiving device shows the same message
    And the receiving device attributes it to the sending device
    And both devices agree the message crossed
