@product
Feature: Localization
  As a Tails user
  I want Tails to be localized in my native language
  And various Tails features should still work

  @doc @not_release_blocker
  Scenario: The Report an Error launcher opens the support documentation in supported non-English locales
    Given I have started Tails from DVD without network and stopped at Tails Greeter's login screen
    And I log in to a new session in German
    When I double-click on the Report an Error launcher on the desktop
    Then the support documentation page opens in Tor Browser

  Scenario: I can start the Unsafe Browser in a few supported languages
    Given I have started Tails from DVD and logged in and the network is connected
    And I magically allow the Unsafe Browser to be started
    Then I can start the Unsafe Browser in a few supported languages

  @slow @not_release_blocker
  Scenario Outline: Tails is localized for every tier-1 language
    Given I have started Tails from DVD without network and stopped at Tails Greeter's login screen
    When I log in to a new session in <language>
    Then the keyboard layout is set to "<layout>"
    When the network is plugged
    And Tor is ready
    Then DuckDuckGo is the default search engine
    When I enable the screen keyboard
    Then the screen keyboard works in Tor Browser
    And the screen keyboard works in Thunderbird
    And the layout of the screen keyboard is set to "<osk_layout>"

    # This list has to be kept in sync' with our list of tier-1 languages:
    #   https://tails.boum.org/contribute/how/translate/#tier-1-languages

    # Known issues, that this step effectively verifies are still present:
    #  - Not all localized layouts exist in the GNOME screen keyboard: #8444
    #  - Arabic's layout should be "ara": #12638
    Examples:
      | language   | layout | osk_layout |
      | Arabic     | us     | us         |
      | Chinese    | cn     | us         |
      | English    | us     | us         |
      | French     | fr     | fr         |
      | German     | de     | de         |
    # Tests disabled due to #18076
    # | Hindi      | in     | us         |
    # | Indonesian | id     | us         |
      | Italian    | it     | us         |
      | Persian    | ir     | ir         |
      | Portuguese | pt     | us         |
      | Russian    | ru     | ru         |
      | Spanish    | es     | us         |
      | Turkish    | tr     | us         |
